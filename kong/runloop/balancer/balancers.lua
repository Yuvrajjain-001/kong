

local upstreams = require "kong.runloop.balancer.upstreams"
local targets = require "kong.runloop.balancer.targets"
local healthcheckers

local ngx = ngx
local log = ngx.log
local sleep = ngx.sleep
local min = math.min
local max = math.max
local sub = string.sub
local find = string.find
local pairs = pairs


local CRIT = ngx.CRIT
local ERR = ngx.ERR
local DEBUG = ngx.DEBUG

local DEFAULT_WEIGHT = 10   -- default weight for a host, if not provided
local DEFAULT_PORT = 80     -- Default port to use (A and AAAA only) when not provided
local TTL_0_RETRY = 60      -- Maximum life-time for hosts added with ttl=0, requery after it expires
local REQUERY_INTERVAL = 30 -- Interval for requerying failed dns queries
local SRV_0_WEIGHT = 1      -- SRV record with weight 0 should be hit minimally, hence we replace by 1


local balancers_M = {}

local balancer_mt = {}
balancer_mt.__index = balancer_mt

local balancers_by_id = {}
local algorithm_types = {}


balancers_M.errors = setmetatable({
  ERR_DNS_UPDATED = "Cannot get peer, a DNS update changed the balancer structure, please retry",
  ERR_ADDRESS_UNAVAILABLE = "Address is marked as unavailable",
  ERR_NO_PEERS_AVAILABLE = "No peers are available",
  ERR_BALANCER_UNHEALTHY = "Balancer is unhealthy",
}, {
  __index = function(_, key)
    error("invalid key: " .. tostring(key))
  end
})


function balancers_M.init()
  healthcheckers = require "kong.runloop.balancer.healthcheckers"
end


function balancers_M.get_balancer_by_id(id)
  return balancers_by_id[id]
end

function balancers_M.set_balancer(upstream_id, balancer)
  local prev = balancers_by_id[upstream_id]
  if prev then
    prev.healthchecker = nil
    prev.healthchecker_callbacks = nil
    prev.upstream_id = nil
  end
  balancers_by_id[upstream_id] = balancer
end


function balancers_M.get_upstream(balancer)
  local upstream_id = balancer.upstream_id
  return upstream_id and upstreams.get_upstream_by_id(upstream_id)
end


local creating = {}

local function wait(id)
  local timeout = 30
  local step = 0.001
  local ratio = 2
  local max_step = 0.5
  while timeout > 0 do
    sleep(step)
    timeout = timeout - step
    if not creating[id] then
      return true
    end
    if timeout <= 0 then
      break
    end
    step = min(max(0.001, step * ratio), timeout, max_step)
  end
  return nil, "timeout"
end

------------------------------------------------------------------------------
-- The mutually-exclusive section used internally by the
-- 'create_balancer' operation.
-- @param upstream (table) A db.upstreams entity
-- @return The new balancer object, or nil+error
local function create_balancer_exclusive(upstream)
  local health_threshold = upstream.healthchecks and
    upstream.healthchecks.threshold or nil

  local targets_list, err = targets.fetch_targets(upstream)
  if not targets_list then
    return nil, "failed fetching targets:" .. err
  end

  if algorithm_types == nil then
    algorithm_types = {
      --["consistent-hashing"] = require("resty.dns.balancer.consistent_hashing"),
      --["least-connections"] = require("resty.dns.balancer.least_connections"),
      ["round-robin"] = require("kong.runloop.balancer.round_robin"),
    }
  end

  local balancer = setmetatable({
    upstream_id = upstream.id,
    log_prefix = "upstream:" .. upstream.name,
    wheelSize = upstream.slots,  -- will be ignored by least-connections
    healthThreshold = health_threshold,
    hosts = targets_list,


    resolveTimer = nil,
    requeryInterval = opts.requery or REQUERY_INTERVAL,  -- how often to requery failed dns lookups (seconds)
    ttl0Interval = opts.ttl0 or TTL_0_RETRY, -- refreshing ttl=0 records
    healthy = false, -- initial healthstatus of the balancer
    healthThreshold = opts.healthThreshold or 0, -- % healthy weight for overall balancer health
    useSRVname = not not opts.useSRVname, -- force to boolean
  }, balancer_mt)
  if not balancer then
    return nil, "failed creating balancer:" .. err
  end

  local algorithm, err = algorithm_types[upstream.algorithm].new({
    balancer = balancer,
    upstream = upstream,
  })
  if not algorithm then
    return nil, "failed instantiating the " .. upstream.algorithm .. " algorithm:" .. err
  end
  balancer.algorithm = algorithm

  --add_targets(balancer, targets_list)

  --balancer.upstream_id = upstream.id

  --if healthcheckers == nil then
  --  healthcheckers = require "kong.runloop.balancer.healthcheckers"
  --end

  local ok, err = healthcheckers.create_healthchecker(balancer, upstream)
  if not ok then
    log(ERR, "[healthchecks] error creating health checker: ", err)
  end

  -- only make the new balancer available for other requests after it
  -- is fully set up.
  balancers_M.set_balancer(upstream.id, balancer)

  return balancer
end

------------------------------------------------------------------------------
-- Create a balancer object, its healthchecker and attach them to the
-- necessary data structures. The creation of the balancer happens in a
-- per-worker mutual exclusion section, such that no two requests create the
-- same balancer at the same time.
-- @param upstream (table) A db.upstreams entity
-- @param recreate (boolean, optional) create new balancer even if one exists
-- @return The new balancer object, or nil+error
function balancers_M.create_balancer(upstream, recreate)

  if balancers_by_id[upstream.id] and not recreate then
    return balancers_by_id[upstream.id]
  end

  if creating[upstream.id] then
    local ok = wait(upstream.id)
    if not ok then
      return nil, "timeout waiting for balancer for " .. upstream.id
    end
    return balancers_by_id[upstream.id]
  end

  creating[upstream.id] = true

  local balancer, err = create_balancer_exclusive(upstream)

  creating[upstream.id] = nil
  upstreams.setUpstream_by_name(upstream)

  return balancer, err
end


-- looks up a balancer for the target.
-- @param target the table with the target details
-- @param no_create (optional) if true, do not attempt to create
-- (for thorough testing purposes)
-- @return balancer if found, `false` if not found, or nil+error on error
function balancers_M.get_balancer(target, no_create)
  -- NOTE: only called upon first lookup, so `cache_only` limitations
  -- do not apply here
  local hostname = target.host

  -- first go and find the upstream object, from cache or the db
  local upstream, err = upstreams.get_upstream_by_name(hostname)
  if upstream == false then
    return false -- no upstream by this name
  end
  if err then
    return nil, err -- there was an error
  end

  local balancer = balancers_by_id[upstream.id]
  if not balancer then
    if no_create then
      return nil, "balancer not found"
    else
      log(ERR, "balancer not found for ", upstream.name, ", will create it")
      return balancers_M.create_balancer(upstream), upstream
    end
  end

  return balancer, upstream
end


function balancers_M.create_balancers()
  local all_upstreams, err = upstreams.get_all_upstreams()
  if not all_upstreams then
    log(CRIT, "failed loading initial list of upstreams: ", err)
    return
  end

  local oks, errs = 0, 0
  for ws_and_name, id in pairs(all_upstreams) do
    local name = sub(ws_and_name, (find(ws_and_name, ":", 1, true)))

    local upstream = upstreams.get_upstream_by_id(id)
    local ok, err
    if upstream ~= nil then
      ok, err = balancers_M.create_balancer(upstream)
    end
    if ok ~= nil then
      oks = oks + 1
    else
      log(CRIT, "failed creating balancer for ", name, ": ", err)
      errs = errs + 1
    end
  end
  log(DEBUG, "initialized ", oks, " balancer(s), ", errs, " error(s)")
end

--------- balancer object methods

function balancer_mt:addressIter()
end

function balancer_mt:setAddressStatus()
end

function balancer_mt:disableAddress(host, address)
  -- from host:disableAddress()
end

function balancer_mt:addAddress(host, address)
  -- from host:addAddress
end

function balancer_mt:changeWeight(oldEndry, newWeight)
  -- from host:findAddress() + address:change()
end

function balancer_mt:deleteDisabledAddresses(host)
  -- from host:deleteAddresses
end

function balancer_mt:setCallback()
end

function balancer_mt:getSatus()
end

-- replaces host:getSatus() for each host
function balancer_mt:getHealthStatus()
end

function balancer_mt:getPeer()
end

return balancers_M
