-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local cjson = require "cjson"
local pl_file = require "pl.file"
local pl_sort = require "pl.tablex".sort
local utils = require "kong.tools.utils"
local find = string.find
local lower = string.lower


local _M = {}

local SIGNING_ALGORITHM = "SHA256"

local signing_key


local function is_json_body(content_type)
  return content_type and find(lower(content_type), "application/json", nil, true)
end


local function filter_table(data, attributes)
  if type(data) ~= "table" then return data, nil end

  local excluded = {}
  for _, v in ipairs(attributes) do
    if data[v] ~= nil then
      table.insert(excluded, v)
      data[v] = nil
    end
  end

  return data, excluded
end


local function serialize(data)
  local p = {}

  for k, v in pl_sort(data) do
    if type(v) == "table" then
      p[#p + 1] = serialize(v)
    else
      p[#p + 1] = v
    end
  end

  return p
end


local function sign_adjacent(data)
  if not signing_key then
    local resty_rsa = require "resty.rsa"


    local k = kong.configuration.audit_log_signing_key
    local err


    signing_key, err = resty_rsa:new({
      private_key = pl_file.read(k),
      algorithm   = SIGNING_ALGORITHM,
    })
    if not signing_key then
      ngx.log(ngx.ERR, "Could not create signing key object: ", err)
      return
    end
  end


  local sig, err = signing_key:sign(table.concat(serialize(data), "|"))
  if not sig then
    ngx.log(ngx.ERR, err)
    return
  end


  data.signature = ngx.encode_base64(sig)


  return
end


local function dao_audit_handler(data)
  if data.schema.name == "audit_objects" or data.schema.name == "audit_requests" then
    return
  end

  if utils.table_contains(kong.configuration.audit_log_ignore_tables,
                          data.schema.name) then
    return
  end

  local pk_field = data.schema.primary_key[1]
  local pk_value = data.entity[pk_field]

  if type(pk_value) == "table" then -- the pk may contain a foreign relationship;
    pk_value = pk_value[next(pk_value)] -- in this case, it'll be a table
  end

  data = {
    request_id = data.request_id or utils.get_request_id(),
    entity_key = pk_value,
    dao_name   = data.schema.table or data.schema.name,
    operation  = data.operation,
    entity     = cjson.encode(data.entity),
  }

  local ttl = kong.configuration.audit_log_record_ttl

  if type(ngx.ctx.rbac) == "table" then
    data.rbac_user_id = ngx.ctx.rbac.user.id
  end


  if kong.configuration.audit_log_signing_key then
    sign_adjacent(data)
  end

  local ok, err = kong.db.audit_objects:insert(data,
    { ttl = ttl, no_broadcast_crud_event = true }
  )
  if not ok then
    ngx.log(ngx.ERR, "failed to write audit log entry: ", err)
  end


  return
end
_M.dao_audit_handler = dao_audit_handler


local function audit_log_writer(_, data)
  local ttl = kong.configuration.audit_log_record_ttl

  local ok, err = kong.db.audit_requests:insert(data,
    { ttl = ttl, no_broadcast_crud_event = true }
  )
  if not ok then
    ngx.log(ngx.ERR, "failed to write audit log entry: ", err)
  end

  return
end


local function admin_log_handler()
  -- if we never started the lapis execution (because this is an OPTIONS
  -- request or something as such)
  if not ngx.ctx.admin_api then
    return
  end

  if not kong.configuration.audit_log then
    return
  end

  if utils.table_contains(kong.configuration.audit_log_ignore_methods,
                          ngx.req.get_method()) then
    return
  end

  local uri = ngx.var.request_uri

  if kong.configuration.audit_log_ignore_paths then
    local from, err

    for _, p in ipairs(kong.configuration.audit_log_ignore_paths) do
      from, _, err = ngx.re.find(uri, p, "jo")

      -- Match is found. Return and don't generate an audit log entry.
      if from then
        return

      -- Bad regex or PCRE error.
      elseif err then
        kong.log.err("could not evaluate the regex " .. p ..
                     " in the configuration audit_log_ignore_paths: ", err)
      end

      -- No match is found.
    end
  end

  local filtered_payload = ngx.req.get_body_data()
  local attributes_filtered

  -- check if the request content-type is an application/json
  -- if so then filter data
  local content_type = ngx.req.get_headers()["content-type"]
  if(content_type and is_json_body(content_type)) then
    local err
    local ok, res = pcall(cjson.decode, filtered_payload)

    if not ok then
      err = res
    end

    if ok then
      filtered_payload, attributes_filtered = filter_table(
        res,
        kong.configuration.audit_log_payload_exclude
      )

      filtered_payload, err = cjson.encode(filtered_payload)
      attributes_filtered = #attributes_filtered > 0 and table.concat(attributes_filtered, ',') or nil
    end

    if err then
      kong.log.err("could not deserialize/serialize JSON payload to table: ", err)
    end
  end



  local data = {
    request_id           = utils.get_request_id(),
    client_ip            = ngx.var.remote_addr,
    path                 = uri,
    payload              = filtered_payload,
    removed_from_payload = attributes_filtered,
    method               = ngx.req.get_method(),
    status               = ngx.status,
    workspace            = ngx.ctx.workspace,
  }


  if type(ngx.ctx.rbac) == "table" then
    data.rbac_user_id = ngx.ctx.rbac.user.id
  end


  if kong.configuration.audit_log_signing_key then
    sign_adjacent(data)
  end


  local ok, err = ngx.timer.at(0, audit_log_writer, data)
  if not ok then
    ngx.log(ngx.ERR, "failed creating dummy req for audit log write: ", err)
  end


  return
end
_M.admin_log_handler = admin_log_handler


return _M
