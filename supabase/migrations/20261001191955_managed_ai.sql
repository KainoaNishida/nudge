-- No conversation content belongs in this database. All API access is service-role only.
create table public.nudge_memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active boolean not null default true,
  consent_version integer not null default 0,
  created_at timestamptz not null default now()
);
create table public.nudge_config (
  id boolean primary key default true check(id),
  rollout_enabled boolean not null default false,
  kill_switch boolean not null default false,
  global_cap_microusd bigint not null default 100000000 check(global_cap_microusd >= 0),
  model text not null default 'gemini-3.8-flash',
  consent_version integer not null default 1
);
insert into public.nudge_config(id) values(true);
create table public.nudge_pricing (
  version text primary key, model text not null,
  effective_at timestamptz not null, expires_at timestamptz not null check(expires_at > effective_at),
  input_usd_per_million numeric not null check(input_usd_per_million>0),
  output_usd_per_million numeric not null check(output_usd_per_million>0)
);
insert into public.nudge_pricing values ('gemini-3.8-flash-2026-09','gemini-3.8-flash','2026-09-01Z','2027-01-01Z',0.75,3.75);
-- Expired pricing fails closed. Owner must review and insert the next effective price.
create table public.nudge_monthly_global (
  month date primary key, charged_microusd bigint not null default 0 check(charged_microusd>=0)
);
create table public.nudge_monthly_users (
  user_id uuid references auth.users(id) on delete cascade,
  month date not null, charged_microusd bigint not null default 0 check(charged_microusd>=0), primary key(user_id,month)
);
create table public.nudge_requests (
  user_id uuid references auth.users(id) on delete cascade,
  request_id uuid not null, run_id uuid not null, endpoint text not null check(endpoint in ('assess','rank')),
  month date not null, state text not null check(state in ('reserved','completed','failed','ambiguous')),
  reserved_microusd bigint not null check(reserved_microusd>=0), charged_microusd bigint not null check(charged_microusd>=0),
  input_bound integer not null, output_bound integer not null,
  input_tokens integer, output_tokens integer, thinking_tokens integer,
  model text not null, pricing_version text not null references public.nudge_pricing(version),
  created_at timestamptz not null default now(), finished_at timestamptz,
  primary key(user_id,request_id)
);
create index nudge_requests_user_recent on public.nudge_requests(user_id,created_at desc);
create index nudge_requests_running on public.nudge_requests(user_id) where state='reserved';

alter table public.nudge_memberships enable row level security;
alter table public.nudge_config enable row level security;
alter table public.nudge_pricing enable row level security;
alter table public.nudge_monthly_global enable row level security;
alter table public.nudge_monthly_users enable row level security;
alter table public.nudge_requests enable row level security;
revoke all on public.nudge_memberships,public.nudge_config,public.nudge_pricing,public.nudge_monthly_global,public.nudge_monthly_users,public.nudge_requests from public,anon,authenticated;
grant all on public.nudge_memberships,public.nudge_config,public.nudge_pricing,public.nudge_monthly_global,public.nudge_monthly_users,public.nudge_requests to service_role;

create function public.nudge_reserve(p_user uuid,p_request uuid,p_run uuid,p_endpoint text,p_input_bound integer,p_consent integer)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 c public.nudge_config%rowtype; price public.nudge_pricing%rowtype; existing public.nudge_requests%rowtype;
 t timestamptz := clock_timestamp(); m date := date_trunc('month',clock_timestamp() at time zone 'UTC')::date;
 cost bigint; user_spent bigint; global_spent bigint;
begin
 -- A single short row lock serializes all reservations, reconciliation and deletion.
 select * into c from public.nudge_config where id=true for update;
 if not exists(select 1 from public.nudge_memberships where user_id=p_user and active) then return jsonb_build_object('error','access_denied'); end if;
 select * into existing from public.nudge_requests where user_id=p_user and request_id=p_request;
 if found then return jsonb_build_object('error',case when existing.state='reserved' then 'request_in_progress' else 'response_not_replayable' end); end if;
 if c.kill_switch or not c.rollout_enabled then return jsonb_build_object('error','service_paused'); end if;
 if p_consent<>c.consent_version then return jsonb_build_object('error','consent_required'); end if;
 if p_input_bound<1 or p_input_bound>300000 or p_endpoint not in ('assess','rank') then return jsonb_build_object('error','invalid_limits'); end if;
 select * into price from public.nudge_pricing where model=c.model and effective_at<=t and expires_at>t order by effective_at desc limit 1;
 if not found then return jsonb_build_object('error','pricing_unavailable'); end if;
 -- Expired reservations keep their entire charge; their provider calls have passed the 90s timeout.
 update public.nudge_requests set state='ambiguous',finished_at=t where user_id=p_user and state='reserved' and created_at<t-interval '3 minutes';
 if (select count(*) from public.nudge_requests where user_id=p_user and state='reserved')>=2 then return jsonb_build_object('error','concurrency_limit'); end if;
 if (select count(*) from public.nudge_requests where user_id=p_user and created_at>t-interval '1 minute')>=12 then return jsonb_build_object('error','rate_limit'); end if;
 -- Interactions max_output_tokens is a combined bound on visible output and thinking.
 cost := ceil(p_input_bound*price.input_usd_per_million + 8192*price.output_usd_per_million);
 insert into public.nudge_monthly_global(month) values(m) on conflict do nothing;
 insert into public.nudge_monthly_users(user_id,month) values(p_user,m) on conflict do nothing;
 select charged_microusd into user_spent from public.nudge_monthly_users where user_id=p_user and month=m;
 select charged_microusd into global_spent from public.nudge_monthly_global where month=m;
 if user_spent+cost>5000000 then return jsonb_build_object('error','quota_exhausted'); end if;
 if global_spent+cost>c.global_cap_microusd then return jsonb_build_object('error','global_quota_exhausted'); end if;
 update public.nudge_monthly_users set charged_microusd=charged_microusd+cost where user_id=p_user and month=m;
 update public.nudge_monthly_global set charged_microusd=charged_microusd+cost where month=m;
 update public.nudge_memberships set consent_version=p_consent where user_id=p_user;
 insert into public.nudge_requests(user_id,request_id,run_id,endpoint,month,state,reserved_microusd,charged_microusd,input_bound,output_bound,model,pricing_version)
 values(p_user,p_request,p_run,p_endpoint,m,'reserved',cost,cost,p_input_bound,8192,c.model,price.version);
 return jsonb_build_object('model',c.model,'reservedMicrousd',cost,'pricingVersion',price.version);
end $$;

create function public.nudge_finish(p_user uuid,p_request uuid,p_state text,p_input integer default null,p_output integer default null,p_thinking integer default null)
returns void language plpgsql security invoker set search_path='' as $$
declare r public.nudge_requests%rowtype; price public.nudge_pricing%rowtype; cost bigint; delta bigint;
begin
 perform 1 from public.nudge_config where id=true for update;
 select * into r from public.nudge_requests where user_id=p_user and request_id=p_request;
 if not found or r.state<>'reserved' then return; end if;
 if p_state not in ('completed','failed','ambiguous') then raise exception 'invalid_state'; end if;
 cost := r.reserved_microusd;
 if p_input is not null and p_output is not null and p_thinking is not null and least(p_input,p_output,p_thinking)>=0 then
   select * into price from public.nudge_pricing where version=r.pricing_version;
   cost := ceil(p_input*price.input_usd_per_million+(p_output+p_thinking)*price.output_usd_per_million);
   if p_input>r.input_bound or p_output+p_thinking>r.output_bound then
     update public.nudge_config set kill_switch=true where id=true;
   end if;
 end if;
 delta := r.charged_microusd-cost;
 update public.nudge_monthly_users set charged_microusd=charged_microusd-delta where user_id=p_user and month=r.month;
 update public.nudge_monthly_global set charged_microusd=charged_microusd-delta where month=r.month;
 update public.nudge_requests set state=p_state,charged_microusd=cost,input_tokens=p_input,output_tokens=p_output,thinking_tokens=p_thinking,finished_at=clock_timestamp() where user_id=p_user and request_id=p_request;
end $$;

create function public.nudge_status(p_user uuid) returns jsonb language sql security invoker set search_path='' as $$
 select jsonb_build_object('schemaVersion',1,'access',exists(select 1 from public.nudge_memberships where user_id=p_user and active),
 'rolloutEnabled',c.rollout_enabled and not c.kill_switch,
 'remainingUSD',greatest(0,5000000-coalesce((select charged_microusd from public.nudge_monthly_users where user_id=p_user and month=date_trunc('month',now() at time zone 'UTC')::date),0))/1000000.0,
 'resetsAt',to_char((date_trunc('month',now() at time zone 'UTC')+interval '1 month'),'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
 'model',c.model,'assessPromptVersion','assess-v1','rankPromptVersion','rank-v1','consentVersion',c.consent_version)
 from public.nudge_config c where id=true
$$;
create function public.nudge_revoke(p_user uuid) returns void language plpgsql security invoker set search_path='' as $$
begin
 perform 1 from public.nudge_config where id=true for update;
 -- Delete access before deleting Auth; stale JWTs cannot authorize another inference.
 delete from public.nudge_memberships where user_id=p_user;
 delete from public.nudge_requests where user_id=p_user;
 delete from public.nudge_monthly_users where user_id=p_user;
 -- Aggregate global charges intentionally retain no account identity.
end $$;
revoke all on function public.nudge_reserve(uuid,uuid,uuid,text,integer,integer), public.nudge_finish(uuid,uuid,text,integer,integer,integer),public.nudge_status(uuid),public.nudge_revoke(uuid) from public,anon,authenticated;
grant execute on function public.nudge_reserve(uuid,uuid,uuid,text,integer,integer), public.nudge_finish(uuid,uuid,text,integer,integer,integer),public.nudge_status(uuid),public.nudge_revoke(uuid) to service_role;
