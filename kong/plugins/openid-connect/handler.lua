local BasePlugin      = require "kong.plugins.base_plugin"
local cache           = require "kong.plugins.openid-connect.cache"
local arguments       = require "kong.plugins.openid-connect.arguments"
local log             = require "kong.plugins.openid-connect.log"
local constants       = require "kong.constants"
local responses       = require "kong.tools.responses"
local openid          = require "kong.openid-connect"
local uri             = require "kong.openid-connect.uri"
local set             = require "kong.openid-connect.set"
local codec           = require "kong.openid-connect.codec"
local session_factory = require "resty.session"


local ngx             = ngx
local redirect        = ngx.redirect
local var             = ngx.var
local time            = ngx.time
local header          = ngx.header
local set_header      = ngx.req.set_header
local escape_uri      = ngx.escape_uri
local tonumber        = tonumber
local tostring        = tostring
local ipairs          = ipairs
local concat          = table.concat
local find            = string.find
local type            = type
local sub             = string.sub
local max             = math.max
local json            = codec.json
local base64          = codec.base64


local PARAM_TYPES_ALL = {
  "header",
  "query",
  "body",
}


local function unexpected(trusted_client, ...)
  log.err(...)

  if trusted_client.unexpected_redirect_uri then
    return redirect(trusted_client.unexpected_redirect_uri)
  end

  return responses.send_HTTP_INTERNAL_SERVER_ERROR()
end


local function create_session_open(args, secret)
  local storage = args.get_conf_arg("session_storage", "cookie")
  local redis, memcache

  if storage == "memcache" then
    log("loading configuration for memcache session storage")
    memcache = {
      uselocking = false,
      prefix     = args.get_conf_arg("session_memcache_prefix", "sessions"),
      socket     = args.get_conf_arg("session_memcache_socket"),
      host       = args.get_conf_arg("session_memcache_host", "127.0.0.1"),
      port       = args.get_conf_arg("session_memcache_port", 11211),
    }

  elseif storage == "redis" then
    log("loading configuration for redis session storage")
    redis = {
      uselocking = false,
      prefix     = args.get_conf_arg("session_redis_prefix", "sessions"),
      socket     = args.get_conf_arg("session_redis_socket"),
      host       = args.get_conf_arg("session_redis_host", "127.0.0.1"),
      port       = args.get_conf_arg("session_redis_port", 6379),
      auth       = args.get_conf_arg("session_redis_auth"),
    }
  end

  return function(options)
    options.storage  = storage
    options.memcache = memcache
    options.redis    = redis
    options.secret   = secret

    log("trying to open session using cookie named '", options.name, "'")
    return session_factory.open(options)
  end
end


local function create_get_http_opts(args)
  return function(options)
    options = options or {}
    options.http_version = args.get_conf_arg("http_version", 1.1)
    options.ssl_verify   = args.get_conf_arg("ssl_verify",   true)
    options.timeout      = args.get_conf_arg("timeout",      10000)
    return options
  end
end


local function create_introspect_token(args, oic)
  local endpoint = args.get_conf_arg("introspection_endpoint")
  local hint     = args.get_conf_arg("introspection_hint", "access_token")
  local headers  = args.get_conf_args("introspection_headers_names", "introspection_headers_values")

  if args.get_conf_arg("cache_introspection") then
    return function(access_token, ttl)
        log("introspecting token with caching enabled")
        return cache.introspection.load(oic, access_token, endpoint, hint, headers, ttl, true)
    end
  end

  return function(access_token, ttl)
    log("introspecting token")
    return cache.introspection.load(oic, access_token, endpoint, hint, headers, ttl, false)
  end
end


local function redirect_uri()
  -- we try to use current url as a redirect_uri by default
  -- if none is configured.

  local scheme = var.scheme
  if type(scheme) == "table" then
    scheme = scheme[1]
  end

  local host = var.host
  if type(host) == "table" then
    host = host[1]
  end

  local port = var.server_port
  if type(port) == "table" then
    port = port[1]
  end

  port = tonumber(port)

  local u = var.request_uri
  if type(u) == "table" then
    u = u[1]
  end

  do
    local s = find(u, "?", 2, true)
    if s then
      u = sub(u, 1, s - 1)
    end
  end

  local url = { scheme, "://", host }

  if port == 80 and scheme == "http" then
    url[4] = u

  elseif port == 443 and scheme == "https" then
    url[4] = u

  else
    url[4] = ":"
    url[5] = port
    url[6] = u
  end

  return concat(url)
end


local function find_consumer(token, claim, anonymous, consumer_by, ttl)
  if not token then
    return nil, "token for consumer mapping was not found"
  end

  if type(token) ~= "table" then
    return nil, "opaque token cannot be used for consumer mapping"
  end

  local payload = token.payload

  if not payload then
    return nil, "token payload was not found for consumer mapping"
  end

  if type(payload) ~= "table" then
    return nil, "invalid token payload was specified for consumer mapping"
  end

  local subject = payload[claim]

  if not subject then
    return nil, "claim (" .. claim .. ") was not found for consumer mapping"
  end

  return cache.consumers.load(subject, anonymous, consumer_by, ttl)
end


local function set_consumer(consumer, credential, is_anonymous)
  if consumer then
    log("setting kong consumer context and headers")

    local head = constants.HEADERS

    ngx.ctx.authenticated_consumer = consumer

    if credential then
      ngx.ctx.authenticated_credential = credential

    else
      if is_anonymous then
        set_header(head.ANONYMOUS, true)

      else
        set_header(head.ANONYMOUS, nil)

        ngx.ctx.authenticated_credential = {
          consumer_id = consumer.id
        }
      end
    end

    set_header(head.CONSUMER_ID,        consumer.id)
    set_header(head.CONSUMER_CUSTOM_ID, consumer.custom_id)
    set_header(head.CONSUMER_USERNAME,  consumer.username)

  else
    log("removing possible remnants of anonymous")

    ngx.ctx.authenticated_consumer   = nil
    ngx.ctx.authenticated_credential = nil

    local head = constants.HEADERS

    set_header(head.CONSUMER_ID,        nil)
    set_header(head.CONSUMER_CUSTOM_ID, nil)
    set_header(head.CONSUMER_USERNAME,  nil)

    set_header(head.ANONYMOUS,          nil)
  end
end


local function find_trusted_client_by_arg(arg, clients)
  if not arg then
    return nil
  end

  local client_index = tonumber(arg)
  if client_index then
    if clients[client_index] then
      local client_id = clients[client_index]
      if client_id then
        return client_id, client_index
      end
    end

    return
  end

  for i, c in ipairs(clients) do
    if arg == c then
      return clients[i], i
    end
  end
end


local function find_trusted_client(args)
  -- load client configuration
  local clients   = args.get_conf_arg("client_id",     {})
  local secrets   = args.get_conf_arg("client_secret", {})
  local redirects = args.get_conf_arg("redirect_uri",  {})

  local login_redirect_uris        = args.get_conf_arg("login_redirect_uri",        {})
  local logout_redirect_uris       = args.get_conf_arg("logout_redirect_uri",       {})
  local forbidden_redirect_uris    = args.get_conf_arg("forbidden_redirect_uri",    {})
  local unauthorized_redirect_uris = args.get_conf_arg("unauthorized_redirect_uri", {})
  local unexpected_redirect_uris   = args.get_conf_arg("unexpected_redirect_uris",  {})

  clients.n = #clients

  local client_id
  local client_index

  if clients.n > 1 then
    local client_arg_name = args.get_conf_arg("client_arg", "client_id")

    client_id, client_index = find_trusted_client_by_arg(args.get_header(client_arg_name, "X"), clients)
    if not client_id then
      client_id, client_index = find_trusted_client_by_arg(args.get_uri_arg(client_arg_name), clients)
      if not client_id then
        client_id, client_index = find_trusted_client_by_arg(args.get_body_arg(client_arg_name), clients)
      end
    end
  end

  local client = {
    clients                    = clients,
    secrets                    = secrets,
    redirects                  = redirects,
    login_redirect_uris        = login_redirect_uris,
    logout_redirect_uris       = logout_redirect_uris,
    forbidden_redirect_uris    = forbidden_redirect_uris,
    forbidden_destroy_session  = args.get_conf_arg("forbidden_destroy_session", true),
    unauthorized_redirect_uris = unauthorized_redirect_uris,
    unexpected_redirect_uris   = unexpected_redirect_uris,
  }

  if client_id then
    client.id                        = client_id
    client.index                     = client_index
    client.secret                    = secrets[client_index]                    or secrets[1]
    client.redirect_uri              = redirects[client_index]                  or redirects[1] or redirect_uri()
    client.login_redirect_uri        = login_redirect_uris[client_index]        or login_redirect_uris[1]
    client.logout_redirect_uri       = logout_redirect_uris[client_index]       or logout_redirect_uris[1]
    client.forbidden_redirect_uri    = forbidden_redirect_uris[client_index]    or forbidden_redirect_uris[1]
    client.unauthorized_redirect_uri = unauthorized_redirect_uris[client_index] or unauthorized_redirect_uris[1]
    client.unexpected_redirect_uri   = unexpected_redirect_uris[client_index]   or unexpected_redirect_uris[1]

  else
    client.id                        = clients[1]
    client.index                     = 1
    client.secret                    = secrets[1]
    client.redirect_uri              = redirects[1] or redirect_uri()
    client.login_redirect_uri        = login_redirect_uris[1]
    client.logout_redirect_uri       = logout_redirect_uris[1]
    client.forbidden_redirect_uri    = forbidden_redirect_uris[1]
    client.unauthorized_redirect_uri = unauthorized_redirect_uris[1]
    client.unexpected_redirect_uri   = unexpected_redirect_uris[1]
  end

  return client
end


local function reset_trusted_client(new_client_index, trusted_client, oic, options)
  if not new_client_index or new_client_index == trusted_client.index or trusted_client.clients.n < 2 then
    return
  end

  local new_id, new_index = find_trusted_client_by_arg(new_client_index, trusted_client.clients)
  if not new_id then
    return
  end

  trusted_client.index                     = new_index
  trusted_client.id                        = new_id
  trusted_client.secret                    = trusted_client.secrets[new_client_index] or
                                             trusted_client.secret
  trusted_client.redirect_uri              = trusted_client.redirects[new_client_index] or
                                             trusted_client.redirect_uri
  trusted_client.login_redirect_uri        = trusted_client.login_redirect_uris[new_client_index] or
                                             trusted_client.login_redirect_uri
  trusted_client.logout_redirect_uri       = trusted_client.logout_redirect_uris[new_client_index] or
                                             trusted_client.logout_redirect_uri
  trusted_client.forbidden_redirect_uri    = trusted_client.forbidden_redirect_uris[new_client_index] or
                                             trusted_client.forbidden_redirect_uri
  trusted_client.unauthorized_redirect_uri = trusted_client.unauthorized_redirect_uris[new_client_index] or
                                             trusted_client.unauthorized_redirect_uri
  trusted_client.unexpected_redirect_uri   = trusted_client.unexpected_redirect_uris[new_client_index] or
                                             trusted_client.unexpected_redirect_uri


  options.client_id     = trusted_client.id
  options.client_secret = trusted_client.secret
  options.redirect_uri  = trusted_client.redirect_uri

  oic.options:reset(options)
end


local function append_header(name, value)
  if type(value) == "table" then
    for _, val in ipairs(value) do
      append_header(name, val)
    end

  else
    local header_value = header[name]

    if header_value ~= nil then
      if type(header_value) == "table" then
        header_value[#header_value+1] = value

      else

        header_value = { header_value, value }
      end

    else
      header_value = value
    end

    header[name] = header_value
  end
end


local function set_upstream_header(header_key, header_value)
  if not header_key or not header_value then
    return
  end

  if header_key == "authorization:bearer" then
    set_header("Authorization", "Bearer " .. header_value)

  elseif header_key == "authorization:basic" then
    set_header("Authorization", "Basic " .. header_value)

  else
    set_header(header_key, header_value)
  end
end


local function set_downstream_header(header_key, header_value)
  if header_key == "authorization:bearer" then
    append_header("Authorization", "Bearer " .. header_value)

  elseif header_key == "authorization:basic" then
    append_header("Authorization", "Basic " .. header_value)

  else
    append_header(header_key, header_value)
  end
end


local function get_header_value(header_value)
  if not header_value then
    return
  end

  local val_type = type(header_value)
  if val_type == "function" then
    return get_header_value(header_value())

  elseif val_type == "table" then
    header_value = json.encode(header_value)
    if header_value then
      header_value = base64.encode(header_value)
    end

  elseif val_type ~= "string" then
    return tostring(header_value)
  end

  return header_value
end


local function set_headers(args, header_key, header_value)
  local us = "upstream_"   .. header_key
  local ds = "downstream_" .. header_key

  do
    local value

    local usm = args.get_conf_arg(us .. "_header")
    if usm then
      value = get_header_value(header_value)
      if value then
        set_upstream_header(usm, value)
      end
    end

    local dsm = args.get_conf_arg(ds .. "_header")
    if dsm then
      if not usm then
        value = get_header_value(header_value)
      end

      if value then
        set_downstream_header(dsm, value)
      end
    end
  end
end


local function anonymous_access(anonymous, trusted_client)
  local consumer_token = {
    payload = {
      id = anonymous
    }
  }

  local consumer, err = find_consumer(consumer_token, "id", true, "id")
  if not consumer then
    if err then
      return unexpected(trusted_client, "anonymous consumer was not found (", err, ")")

    else
      return unexpected(trusted_client, "anonymous consumer was not found")
    end
  end

  local head = constants.HEADERS

  ngx.ctx.authenticated_consumer   = consumer
  ngx.ctx.authenticated_credential = nil

  set_header(head.CONSUMER_ID,        consumer.id)
  set_header(head.CONSUMER_CUSTOM_ID, consumer.custom_id)
  set_header(head.CONSUMER_USERNAME,  consumer.username)
  set_header(head.ANONYMOUS,          true)
end


local function unauthorized(issuer, err, session, anonymous, trusted_client)
  if err then
    log.notice(err)
  end

  if session then
    session:destroy()
  end

  if anonymous then
    return anonymous_access(anonymous, trusted_client)
  end

  if trusted_client.unauthorized_redirect_uri then
    return redirect(trusted_client.unauthorized_redirect_uri)
  end

  local parts = uri.parse(issuer)
  header["WWW-Authenticate"] = 'Bearer realm="' .. parts.host .. '"'
  return responses.send_HTTP_UNAUTHORIZED()
end


local function forbidden(issuer, err, session, anonymous, trusted_client)
  if err then
    log.notice(err)
  end

  if session and trusted_client.forbidden_destroy_session then
    session:destroy()
  end

  if anonymous then
    return anonymous_access(anonymous, trusted_client)
  end

  if trusted_client.forbidden_redirect_uri then
    return redirect(trusted_client.forbidden_redirect_uri)
  end

  local parts = uri.parse(issuer)
  header["WWW-Authenticate"] = 'Bearer realm="' .. parts.host .. '"'
  return responses.send_HTTP_FORBIDDEN()
end


local function success(response)
  return responses.send_HTTP_OK(response)
end


local function get_auth_methods(get_conf_arg)
  local auth_methods = get_conf_arg("auth_methods", {
    "password",
    "client_credentials",
    "authorization_code",
    "bearer",
    "introspection",
    "kong_oauth2",
    "refresh_token",
    "session",
  })

  local ret = {}
  for _, auth_method in ipairs(auth_methods) do
    ret[auth_method] = true
  end
  return ret
end


local function decode_basic_auth(basic_auth)
  if not basic_auth then
    return nil
  end

  local s = find(basic_auth, ":", 2, true)
  if s then
    local username = sub(basic_auth, 1, s - 1)
    local password = sub(basic_auth, s + 1)
    return username, password
  end
end


local function get_credentials(args, auth_methods, credential_type, usr_arg, pwd_arg)
  if not auth_methods[credential_type] then
    return
  end

  local password_param_type = args.get_conf_arg(credential_type .. "_param_type", PARAM_TYPES_ALL)

  for _, location in ipairs(password_param_type) do
    if location == "header" then
      local grant_type = args.get_header("Grant-Type", "X")
      if not grant_type or grant_type == credential_type then
        local username, password = decode_basic_auth(args.get_header("authorization:basic"))
        if username and password then
          return username, password, "header"
        end
      end

    elseif location == "query" then
      local grant_type = args.get_uri_arg("grant_type")
      if not grant_type or grant_type == credential_type then
        local username = args.get_uri_arg(usr_arg)
        local password = args.get_uri_arg(pwd_arg)
        if username and password then
          return username, password, "uri"
        end
      end

    elseif location == "body" then
      local grant_type = args.get_body_arg("grant_type")
      if not grant_type or grant_type == credential_type then
        local username, loc = args.get_body_arg(usr_arg)
        local password = args.get_body_arg(pwd_arg)
        if username and password then
          return username, password, loc
        end
      end
    end
  end
end


local function replay_downstream_headers(args, headers, auth_method)
  if headers and auth_method then
    local replay_for = args.get_conf_arg("token_headers_grants")
    if not replay_for then
      return
    end
    log("replaying token endpoint request headers")
    local replay_prefix = args.get_conf_arg("token_headers_prefix")
    for _, v in ipairs(replay_for) do
      if v == auth_method then
        local replay_headers = args.get_conf_arg("token_headers_replay")
        if replay_headers then
          for _, replay_header in ipairs(replay_headers) do
            local extra_header = headers[replay_header]
            if extra_header then
              if replay_prefix then
                append_header(replay_prefix .. replay_header, extra_header)

              else
                append_header(replay_header, extra_header)
              end
            end
          end
        end
        return
      end
    end
  end
end


local function get_exp(access_token, tokens_encoded, now, exp_default)
  if access_token and type(access_token) == "table" then
    local exp = tonumber(access_token.exp)
    if exp then
      return exp
    end

  elseif tokens_encoded and type(tokens_encoded) == "table" then
    local expires_in = tonumber(tokens_encoded.expires_in)
    if expires_in then
      return now + expires_in
    end
  end

  return exp_default
end


local function no_cache_headers()
  header["Cache-Control"] = "no-cache, no-store"
  header["Pragma"]        = "no-cache"
end


local OICHandler = BasePlugin:extend()


function OICHandler:new()
  OICHandler.super.new(self, "openid-connect")
end


function OICHandler:init_worker()
  OICHandler.super.init_worker(self)
  cache.init_worker()
end


function OICHandler:access(conf)
  OICHandler.super.access(self)

  local args = arguments(conf)
  args.get_http_opts = create_get_http_opts(args)

  -- check if preflight request and whether it should be authenticated
  if not args.get_conf_arg("run_on_preflight", true) and var.request_method == "OPTIONS" then
    return
  end

  local trusted_client = find_trusted_client(args)

  local anonymous = args.get_conf_arg("anonymous")
  if anonymous and ngx.ctx.authenticated_credential then
    -- we're already authenticated, and we're configured for using anonymous,
    -- hence we're in a logical OR between auth methods and we're already done.
    log("skipping because user is already authenticated")
    return
  end

  -- common variables
  local ok, err

  -- load discovery information
  log("loading discovery information")
  local oic, iss, secret, options
  do
    local issuer_uri = args.get_conf_arg("issuer")
    if not issuer_uri then
      return unexpected(trusted_client, "issuer was not specified")
    end

    local issuer
    issuer, err = cache.issuers.load(issuer_uri, args.get_http_opts {
      headers = args.get_conf_args("discovery_headers_names", "discovery_headers_values"),
    })

    if not issuer then
      return unexpected(trusted_client, err or "discovery information could not be loaded")
    end

    options = {
      client_id         = trusted_client.id,
      client_secret     = trusted_client.secret,
      redirect_uri      = trusted_client.redirect_uri,
      scope             = args.get_conf_arg("scopes", { "openid" }),
      response_mode     = args.get_conf_arg("response_mode"),
      audience          = args.get_conf_arg("audience"),
      domains           = args.get_conf_arg("domains"),
      max_age           = args.get_conf_arg("max_age"),
      timeout           = args.get_conf_arg("timeout", 10000),
      leeway            = args.get_conf_arg("leeway", 0),
      http_version      = args.get_conf_arg("http_version", 1.1),
      ssl_verify        = args.get_conf_arg("ssl_verify", true),
      verify_parameters = args.get_conf_arg("verify_parameters"),
      verify_nonce      = args.get_conf_arg("verify_nonce"),
      verify_signature  = args.get_conf_arg("verify_signature"),
      verify_claims     = args.get_conf_arg("verify_claims"),
    }

    log("initializing library")
    oic, err = openid.new(options, issuer.configuration, issuer.keys)
    if not oic then
      return unexpected(trusted_client, err or "unable to initialize library")
    end

    iss    = oic.configuration.issuer
    secret = issuer.secret
  end

  -- initialize functions
  local introspect_token = create_introspect_token(args, oic)
  local session_open     = create_session_open(args, secret)

  -- load enabled authentication methods
  local auth_methods = get_auth_methods(args.get_conf_arg)

  -- try to open session
  local session, session_present, session_data
  if auth_methods.session then
    session, session_present = session_open {
      name = args.get_conf_arg("session_cookie_name", "session"),
      cookie = {
        lifetime =  args.get_conf_arg("session_cookie_lifetime", 3600),
      },
    }

    session_data = session.data
  end

  -- logout
  do
    local logout = false
    local logout_methods = args.get_conf_arg("logout_methods", { "POST", "DELETE" })
    if logout_methods then
      local request_method = var.request_method
      for _, logout_method in ipairs(logout_methods) do
        if logout_method == request_method then
          logout = true
          break
        end
      end

      if logout then
        logout = false

        local logout_query_arg = args.get_conf_arg("logout_query_arg")
        if logout_query_arg then
           logout = args.get_uri_arg(logout_query_arg) ~= nil
        end

        if logout then
          log("logout by query argument")

        else
          local logout_uri_suffix = args.get_conf_arg("logout_uri_suffix")
          if logout_uri_suffix then
            logout = sub(var.request_uri, -#logout_uri_suffix) == logout_uri_suffix
            if logout then
              log("logout by uri suffix")

            else
              local logout_post_arg = args.get_conf_arg("logout_post_arg")
              if logout_post_arg then
                logout = args.get_post_arg(logout_post_arg) ~= nil
                if logout then
                  log("logout by post argument")
                end
              end
            end
          end
        end
      end

      if logout then
        local id_token
        if session_present and session_data then
          reset_trusted_client(session_data.client, trusted_client, oic, options)

          if session_data.tokens then
            id_token = session_data.tokens.id_token

            if session_data.tokens.access_token then
              if args.get_conf_arg("logout_revoke", false) then
                log("revoking access token")
                ok, err = oic.token:revoke(session_data.tokens.access_token, "access_token", {
                  revocation_endpoint = args.get_conf_arg("revocation_endpoint")
                })
                if not ok and err then
                  log("revoking access token failed: ", err)
                end
              end
            end
          end

          log("destroying session")
          session:destroy()
        end

        no_cache_headers()

        local end_session_endpoint = args.get_conf_arg("end_session_endpoint", oic.configuration.end_session_endpoint)
        if end_session_endpoint then
          local redirect_params_added = false
          if find(end_session_endpoint, "?", 1, true) then
            redirect_params_added = true
          end

          local u = { end_session_endpoint }
          local i = 1

          if id_token then
            u[i+1] = redirect_params_added and "&id_token_hint=" or "?id_token_hint="
            u[i+2] = id_token
            i=i+2
            redirect_params_added = true
          end

          if trusted_client.logout_redirect_uri then
            u[i+1] = redirect_params_added and "&post_logout_redirect_uri=" or "?post_logout_redirect_uri="
            u[i+2] = escape_uri(trusted_client.logout_redirect_uri)
          end

          log("redirecting to end session endpoint")
          return redirect(concat(u))

        else
          if trusted_client.logout_redirect_uri then
            log("redirecting to logout redirect uri")
            return redirect(trusted_client.logout_redirect_uri)
          end

          log("logout response")
          return responses.send_HTTP_OK()
        end
      end
    end
  end

  -- find credentials
  local token_endpoint_args, bearer_token
  if not session_present then
    local hide_credentials = args.get_conf_arg("hide_credentials", false)

    log("session was not found")
    -- bearer token authentication
    if auth_methods.bearer or auth_methods.introspection then
      log("trying to find bearer token")
      local bearer_token_param_type = args.get_conf_arg("bearer_token_param_type", PARAM_TYPES_ALL)
      for _, location in ipairs(bearer_token_param_type) do
        if location == "header" then
          bearer_token = args.get_header("authorization:bearer")
          if bearer_token then
            if hide_credentials then
              args.clear_header("Authorization")
            end
            break
          end

        elseif location == "query" then
          bearer_token = args.get_uri_arg("access_token")
          if bearer_token then
            if hide_credentials then
              args.clear_uri_arg("access_token")
            end
            break
          end

        elseif location == "body" then
          bearer_token = args.get_post_arg("access_token")
          if bearer_token then
            if hide_credentials then
              args.clear_post_arg("access_token")
            end
            break
          end

          bearer_token = args.get_json_arg("access_token")
          if bearer_token then
            if hide_credentials then
              args.clear_json_arg("access_token")
            end
            break
          end
        end
      end

      if bearer_token then
        log("found bearer token")
        session_data = {
          client = trusted_client.index,
          tokens = {
            access_token = bearer_token,
          },
        }

        -- additionally we can validate the id token as well
        -- and pass it on, if it is passed on the request
        local id_token_param_name = args.get_conf_arg("id_token_param_name")
        if id_token_param_name then
          log("trying to find id token")

          local id_token, loc = args.get_req_arg(
            id_token_param_name,
            args.get_conf_arg("id_token_param_type", PARAM_TYPES_ALL)
          )

          if id_token then
            log("found id token")
            if hide_credentials then
              if loc == "header" then
                args.clear_header(id_token_param_name, "X")

              elseif loc == "uri" then
                args.clear_uri_arg(id_token_param_name)

              elseif loc == "post" then
                args.clear_post_arg(id_token_param_name)

              elseif loc == "json" then
                args.clear_json_arg(id_token_param_name)
              end
            end

            session_data.tokens.id_token = id_token

          else
            log("id token was not found")
          end
        end

      else
        log("bearer token was not found")
      end
    end

    if not bearer_token then
      do
        log("trying to find credentials for client credentials or password grants")

        local usr, pwd, loc1 = get_credentials(args, auth_methods, "password",           "username",  "password")
        local cid, sec, loc2 = get_credentials(args, auth_methods, "client_credentials", "client_id", "client_secret")

        if usr and pwd and cid and sec then
          log("found credentials and will try both password and client credentials grants")

          token_endpoint_args = {
            {
              username      = usr,
              password      = pwd,
              grant_type    = "password",
            },
            {
              client_id     = cid,
              client_secret = sec,
              grant_type    = "client_credentials",
            },
          }

        elseif usr and pwd then
          log("found credentials for password grant")

          token_endpoint_args = {
            {
              username      = usr,
              password      = pwd,
              grant_type    = "password",
            },
          }

        elseif cid and sec then
          log("found credentials for client credentials grant")

          token_endpoint_args = {
            {
              client_id     = cid,
              client_secret = sec,
              grant_type    = "client_credentials",
            },
          }

        else
          log("credentials for client credentials or password grants were not found")
        end

        if token_endpoint_args and hide_credentials then
          if loc1 == "header" or loc2 == "header" then
            args.clear_header("Authorization", "X")
            args.clear_header("Grant-Type",    "X")
          end

          if loc1 then
            if loc1 == "uri" then
              args.clear_uri_arg("username", "password", "grant_type")

            elseif loc1 == "post" then
              args.clear_post_arg("username", "password", "grant_type")

            elseif loc1 == "json" then
              args.clear_json_arg("username", "password", "grant_type")
            end
          end

          if loc2 then
            if loc2 == "uri" then
              args.clear_uri_arg("client_id", "client_secret", "grant_type")

            elseif loc2 == "post" then
              args.clear_post_arg("client_id", "client_secret", "grant_type")

            elseif loc2 == "json" then
              args.clear_json_arg("client_id", "client_secret", "grant_type")
            end
          end
        end
      end

      if not token_endpoint_args then
        -- authorization code flow
        if auth_methods.authorization_code then
          log("trying to open authorization code flow session")
          local authorization, authorization_present = session_open {
            name = args.get_conf_arg("authorization_cookie_name", "authorization"),
            cookie = {
              lifetime =  args.get_conf_arg("authorization_cookie_lifetime", 600),
              samesite = "off",
            },
          }

          if authorization_present then
            log("found authorization code flow session")

            local authorization_data = authorization.data or {}

            log("checking authorization code flow state")

            local state = authorization_data.state
            if state then
              log("found authorization code flow state")

              local nonce         = authorization_data.nonce
              local code_verifier = authorization_data.code_verifier

              reset_trusted_client(authorization_data.client, trusted_client, oic, options)

              -- authorization code response
              token_endpoint_args = {
                state         = state,
                nonce         = nonce,
                code_verifier = code_verifier,
              }

              log("verifying authorization code flow")

              token_endpoint_args, err = oic.authorization:verify(token_endpoint_args)
              if not token_endpoint_args then
                log("invalid authorization code flow")

                no_cache_headers()

                if args.get_uri_arg("state") == state then
                  return unauthorized(iss, err, authorization, anonymous, trusted_client)

                elseif args.get_post_arg("state") == state then
                  return unauthorized(iss, err, authorization, anonymous, trusted_client)
                end

                log("starting a new authorization code flow with previous parameters")
                -- it seems that user may have opened a second tab
                -- lets redirect that to idp as well in case user
                -- had closed the previous, but with same parameters
                -- as before.
                authorization:start()

                log("creating authorization code flow request with previous parameters")
                token_endpoint_args, err = oic.authorization:request {
                  args          = authorization_data.args,
                  client        = trusted_client.index,
                  state         = state,
                  nonce         = nonce,
                  code_verifier = code_verifier,
                }

                if not token_endpoint_args then
                  log("unable to start authorization code flow request with previous parameters")
                  return unexpected(trusted_client, err)
                end

                log("redirecting client to openid connect provider with previous parameters")
                return redirect(token_endpoint_args.url)
              end

              log("authorization code flow verified")

              authorization:hide()
              authorization:destroy()

              if var.request_method == "POST" then
                args.clear_post_arg("code", "state", "session_state")

              else
                args.clear_uri_arg("code", "state", "session_state")
              end

              token_endpoint_args = { token_endpoint_args }

            else
              log("authorization code flow state was not found")
            end

          else
            log("authorization code flow session was not found")
          end

          if not token_endpoint_args then
            log("creating authorization code flow request")

            no_cache_headers()

            local extra_args  = args.get_conf_args("authorization_query_args_names", "authorization_query_args_values")
            local client_args = args.get_conf_arg("authorization_query_args_client")
            if client_args then
              for _, client_arg_name in ipairs(client_args) do
                local extra_arg = args.get_uri_arg(client_arg_name)
                if extra_arg then
                  if not extra_args then
                    extra_args = {}
                  end

                  extra_args[client_arg_name] = extra_arg

                else
                  extra_arg = args.get_post_arg(client_arg_name)
                  if extra_arg then
                    if not extra_args then
                      extra_args = {}
                    end

                    extra_args[client_arg_name] = extra_arg
                  end
                end
              end
            end

            token_endpoint_args, err = oic.authorization:request {
              args = extra_args,
            }

            if not token_endpoint_args then
              log("unable to start authorization code flow request")
              return unexpected(trusted_client, err)
            end

            authorization.data = {
              args          = extra_args,
              client        = trusted_client.index,
              state         = token_endpoint_args.state,
              nonce         = token_endpoint_args.nonce,
              code_verifier = token_endpoint_args.code_verifier,
            }

            authorization:save()

            log("redirecting client to openid connect provider")
            return redirect(token_endpoint_args.url)

          else
            log("authenticating using authorization code flow")
          end

        else
          return unauthorized(
            iss,
            "no suitable authorization credentials were provided",
            nil,
            anonymous,
            trusted_client)
        end
      end

    else
      log("authenticating using bearer token")
    end

  else
    log("authenticating using session")
  end

  if not session_data then
    session_data = {}
  end

  local credential, consumer

  local now = time()
  local lwy = args.get_conf_arg("leeway", 0)
  local exp
  local ttl

  local ttl_default = args.get_conf_arg("cache_ttl", 3600)
  local exp_default = now + ttl_default

  local tokens_encoded = session_data.tokens
  local tokens_decoded

  local auth_method
  local token_introspected

  local downstream_headers

  -- retrieve or verify tokens
  if bearer_token then
    log("verifying bearer token")

    tokens_decoded, err = oic.token:verify(tokens_encoded)
    if not tokens_decoded then
      log("unable to verify bearer token")
      return unauthorized(iss, err, session, anonymous, trusted_client)
    end

    log("bearer token verified")

    -- introspection of opaque access token
    if type(tokens_decoded.access_token) ~= "table" then
      log("opaque bearer token was provided")

      if auth_methods.kong_oauth2 then
        log("trying to find matching kong oauth2 token")
        token_introspected, credential, consumer = cache.kong_oauth2.load(
          tokens_decoded.access_token, ttl_default, true)
        if token_introspected then
          log("found matching kong oauth2 token")
          token_introspected.active = true

        else
          log("matching kong oauth2 token was not found")
        end
      end

      if not token_introspected then
        if auth_methods.introspection then
          token_introspected = introspect_token(tokens_decoded.access_token, ttl_default)
          if token_introspected then
            if token_introspected.active then
              log("authenticated using oauth2 introspection")

            else
              log("opaque token is not active anymore")
            end

          else
            log("unable to authenticate using oauth2 introspection")
          end
        end

        if not token_introspected or not token_introspected.active then
          log("authentication with opaque bearer token failed")
          return unauthorized(iss, err, session, anonymous, trusted_client)
        end

        auth_method = "introspection"

      else
        auth_method = "kong_oauth2"
      end

      exp = get_exp(token_introspected, tokens_encoded, now, exp_default)

    else
      log("authenticated using jwt bearer token")
      auth_method = "bearer"
      exp = get_exp(tokens_decoded.access_token, tokens_encoded, now, exp_default)
    end

    if auth_methods.session then
      session.data = {
        client  = trusted_client.index,
        tokens  = tokens_encoded,
        expires = exp,
      }
      session:save()
    end

  elseif not tokens_encoded then
    -- let's try to retrieve tokens when using authorization code flow,
    -- password credentials or client credentials
    if token_endpoint_args then
      for _, arg in ipairs(token_endpoint_args) do
        arg.args = args.get_conf_args("token_post_args_names", "token_post_args_values")

        local token_headers_client = args.get_conf_arg("token_headers_client")
        if token_headers_client then
          log("parsing client header for token request")
          local token_headers = {}
          local has_headers
          for _, token_header_name in ipairs(token_headers_client) do
            local token_header_value = args.get_header(token_header_name)
            if token_header_value then
              token_headers[token_header_name] = token_header_value
              has_headers = true
            end
          end
          if has_headers then
            log("injecting client headers to token request")
            arg.headers = token_headers
          end
        end

        if args.get_conf_arg("cache_tokens") then
          log("trying to exchange credentials using token endpoint with caching enabled")
          tokens_encoded, err, downstream_headers = cache.tokens.load(oic, arg, ttl_default, true)

        else
          log("trying to exchange credentials using token endpoint")
          tokens_encoded, err, downstream_headers = cache.tokens.load(oic, arg, ttl_default, false)
        end

        if tokens_encoded then
          log("exchanged credentials with tokens")
          auth_method = arg.grant_type or "authorization_code"
          token_endpoint_args = arg
          break
        end
      end
    end

    if not tokens_encoded then
      log("unable to exchange credentials with tokens")
      return unauthorized(iss, err, session, anonymous, trusted_client)
    end

    log("verifying tokens")
    tokens_decoded, err = oic.token:verify(tokens_encoded, token_endpoint_args)
    if not tokens_decoded then
      log("token verification failed")
      return unauthorized(iss, err, session, anonymous, trusted_client)

    else
      log("tokens verified")
    end

    exp = get_exp(tokens_decoded.access_token, tokens_encoded, now, exp_default)

    if auth_methods.session then
      session.data = {
        client  = trusted_client.index,
        tokens  = tokens_encoded,
        expires = exp,
      }

      if session_present then
        session:regenerate()

      else
        session:save()
      end
    end

  else
    -- it looks like we are using session authentication
    log("authenticated using session")

    auth_method = "session"
    exp = (session_data.expires or lwy)
  end

  log("checking for access token")
  if not tokens_encoded.access_token then
    log("access token was not found")
    return unauthorized(iss, "access token was not found", session, anonymous, trusted_client)

  else
    log("found access token")
  end

  exp = (exp or lwy) - lwy
  ttl = max(exp - now, 0)

  log("checking for access token expiration")

  if exp > now then
    log("access token is valid and has not expired")

    if args.get_conf_arg("reverify") then
      log("reverifying tokens")
      tokens_decoded, err = oic.token:verify(tokens_encoded)
      if not tokens_decoded then
        log("reverifying tokens failed")
        return forbidden(
          iss,
          err,
          session,
          anonymous,
          trusted_client)

      else
        log("reverified tokens")
      end
    end

    if auth_methods.session then
      session:start()
    end

  else
    log("access token has expired")

    if auth_methods.refresh_token then
      -- access token has expired, try to refresh the access token before proxying
      if not tokens_encoded.refresh_token then
        return forbidden(
          iss,
          "access token cannot be refreshed in absense of refresh token",
          session,
          anonymous,
          trusted_client)
      end

      log("trying to refresh access token using refresh token")

      local tokens_refreshed
      local refresh_token = tokens_encoded.refresh_token
      tokens_refreshed, err = oic.token:refresh(refresh_token)

      if not tokens_refreshed then
        log("unable to refresh access token using refresh token")
        return forbidden(
          iss,
          err,
          session,
          anonymous,
          trusted_client)

      else
        log("refreshed access token using refresh token")
      end

      if not tokens_refreshed.id_token then
        tokens_refreshed.id_token = tokens_encoded.id_token
      end

      if not tokens_refreshed.refresh_token then
        tokens_refreshed.refresh_token = refresh_token
      end

      log("verifying refreshed tokens")
      tokens_decoded, err = oic.token:verify(tokens_refreshed)
      if not tokens_decoded then
        log("unable to verify refreshed tokens")
        return forbidden(
          iss,
          err,
          session,
          anonymous,
          trusted_client)

      else
        log("verified refreshed tokens")
      end

      tokens_encoded = tokens_refreshed

      exp = get_exp(tokens_decoded.access_token, tokens_encoded, now, exp_default)

      if auth_methods.session then
        session.data = {
          client  = trusted_client.index,
          tokens  = tokens_encoded,
          expires = exp,
        }

        session:regenerate()
      end

    else
      return forbidden(
        iss,
        "access token has expired and could not be refreshed",
        session,
        anonymous,
        trusted_client)
    end
  end

  -- additional claims verification
  do
    -- additional non-standard verification of the claim against a jwt session cookie
    local jwt_session_cookie = args.get_conf_arg("jwt_session_cookie")
    if jwt_session_cookie then
      if not tokens_decoded then
        tokens_decoded = oic.token:decode(tokens_encoded)
      end

      if tokens_decoded then
        local access_token_decoded = tokens_decoded.access_token
        if type(access_token_decoded) == "table" then
          log("validating jwt claim against jwt session cookie")
          local jwt_session_cookie_value = args.get_value(var["cookie_" .. jwt_session_cookie])
          if not jwt_session_cookie_value then
            return unauthorized(
              iss,
              "jwt session cookie was not specified for session claim verification",
              session,
              anonymous,
              trusted_client)
          end

          local jwt_session_claim = args.get_conf_arg("jwt_session_claim", "sid")
          local jwt_session_claim_value

          jwt_session_claim_value = access_token_decoded[jwt_session_claim]

          if not jwt_session_claim_value then
            return unauthorized(
              iss,
              "jwt session claim (" .. jwt_session_claim .. ") was not specified in jwt access token",
              session,
              anonymous,
              trusted_client)
          end

          if jwt_session_claim_value ~= jwt_session_cookie_value then
            return unauthorized(
              iss,
              "invalid jwt session claim (" .. jwt_session_claim .. ") was specified in jwt access token",
              session,
              anonymous,
              trusted_client)
          end

          log("jwt claim matches jwt session cookie")
        end
      end
    end

    -- scope verification
    local scopes_required = args.get_conf_arg("scopes_required")
    if scopes_required then
      log("verifying required scopes")

      local access_token_scopes
      if token_introspected then
        if token_introspected.scope then
          log("scope claim found in introspection results")
          access_token_scopes = token_introspected.scope

        else
          log("scope claim not found in introspection results")
        end

      else
        if not tokens_decoded then
          tokens_decoded = oic.token:decode(tokens_encoded)
        end

        if tokens_decoded then
          if type(tokens_decoded.access_token) == "table" then
            if tokens_decoded.access_token.payload.scope then
              log("scope claim found in jwt token")
              access_token_scopes = tokens_decoded.access_token.payload.scope

            else
              log("scope claim not found in jwt token")
            end

          else
            token_introspected = introspect_token(tokens_encoded.access_token, ttl)
            if token_introspected then
              if token_introspected.scope then
                log("scope claim found in introspection results")
                access_token_scopes = token_introspected.scope

              else
                log("scope claim not found in introspection results")
              end
            end
          end
        end
      end

      if not access_token_scopes then
        return forbidden(
          iss,
          "scopes required but no scopes found",
          session,
          anonymous,
          trusted_client)
      end

      access_token_scopes = set.new(access_token_scopes)

      local scopes_valid
      for _, scope_required in ipairs(scopes_required) do
        if set.has(scope_required, access_token_scopes) then
          scopes_valid = true
          break
        end
      end

      if scopes_valid then
        log("required scopes were found")

      else
        return forbidden(
          iss,
          "required scopes were not found [ " .. concat(access_token_scopes, ", ") .. " ]",
          session,
          anonymous,
          trusted_client)
      end
    end

    -- audience verification
    local audience_required = args.get_conf_arg("audience_required")
    if audience_required then
      log("verifying required audience")

      local access_token_audience
      if token_introspected then
        if token_introspected.aud then
          log("aud claim found in introspection results")
          access_token_audience = token_introspected.aud

        else
          log("aud claim not found in introspection results")
        end

      else
        if not tokens_decoded then
          tokens_decoded, err = oic.token:decode(tokens_encoded)
        end

        if tokens_decoded then
          if type(tokens_decoded.access_token) == "table" then
            if tokens_decoded.access_token.payload.aud then
              log("aud claim found in jwt token")
              access_token_audience = tokens_decoded.access_token.payload.aud

            else
              log("aud claim not found in jwt token")
            end

          else
            token_introspected = introspect_token(tokens_encoded.access_token, ttl)
            if token_introspected then
              if token_introspected.aud then
                log("aud claim found in introspection results")
                access_token_audience = token_introspected.aud

              else
                log("aud claim not found in introspection results")
              end
            end
          end
        end
      end

      if not access_token_audience then
        return forbidden(
          iss,
          "audience required but no audience found",
          session,
          anonymous,
          trusted_client)
      end

      access_token_audience = set.new(access_token_audience)

      local audience_valid
      for _, aud_required in ipairs(audience_required) do
        if set.has(aud_required, access_token_audience) then
          audience_valid = true
          break
        end
      end

      if audience_valid then
        log("required audience was found")

      else
        return forbidden(
          iss,
          "required audience was not found [ " .. concat(access_token_audience, ", ") .. " ]",
          session,
          anonymous,
          trusted_client)
      end
    end
  end

  -- consumer mapping
  local is_anonymous
  if not consumer then
    local consumer_claim = args.get_conf_arg("consumer_claim")
    if consumer_claim then
      log("trying to find kong consumer")

      local consumer_by = args.get_conf_arg("consumer_by")

      if not tokens_decoded then
        log("decoding tokens")
        tokens_decoded, err = oic.token:decode(tokens_encoded)
      end

      if tokens_decoded then
        local id_token = tokens_decoded.id_token
        if id_token then
          log("trying to find consumer using id token")
          consumer, err = find_consumer(id_token, consumer_claim, false, consumer_by, ttl)
          if not consumer then
            log("trying to find consumer using access token")
            consumer, err = find_consumer(tokens_decoded.access_token, consumer_claim, false, consumer_by, ttl)
          end

        else
          log("trying to find consumer using access token")
          consumer, err = find_consumer(tokens_decoded.access_token, consumer_claim, false, consumer_by, ttl)
        end
      end

      if not consumer and token_introspected then
        log("trying to find consumer using introspection response")
        consumer, err = find_consumer(token_introspected, consumer_claim, false, consumer_by, ttl)
      end

      if not consumer then
        log("kong consumer was not found")
        if not anonymous then
          if err then
            return forbidden(
              iss,
              "consumer was not found (" .. err .. ")",
              session,
              anonymous,
              trusted_client)

          else
            return forbidden(
              iss,
              "consumer was not found",
              session,
              anonymous,
              trusted_client)
          end
        end

        log("trying with anonymous kong consumer")

        is_anonymous = true

        local consumer_token = {
          payload = {
            id = anonymous
          }
        }

        consumer, err = find_consumer(consumer_token, "id", true, "id")
        if not consumer then
          log("anonymous kong consumer was not found")

          if err then
            return unexpected(trusted_client, "anonymous consumer was not found (", err, ")")

          else
            return unexpected(trusted_client, "anonymous consumer was not found")
          end

        else
          log("found anonymous kong consumer")
        end

      else
        log("found kong consumer")
      end

    else
      if anonymous then
        log("trying to find anonymous kong consumer")

        is_anonymous = true

        local consumer_token = {
          payload = {
            id = anonymous
          }
        }

        consumer, err = find_consumer(consumer_token, "id", true, "id")
        if not consumer then
          log("anonymous kong consumer was not found")

          if err then
            return unexpected(trusted_client, "anonymous consumer was not found (", err, ")")

          else
            return unexpected(trusted_client, "anonymous consumer was not found")
          end

        else
          log("found anonymous kong consumer")
        end
      end
    end
  end

  -- setting consumer context and headers
  set_consumer(consumer, credential, is_anonymous)

  -- remove session cookie from the upstream request?
  if auth_methods.session then
    log("hiding session cookie from upstream")
    session:hide()

    if session.close then
      session:close()
    end
  end

  -- here we replay token endpoint request response headers, if any
  replay_downstream_headers(args, downstream_headers, auth_method)

  -- proprietary token exchange
  local token_exchanged
  do
    local exchange_token_endpoint = args.get_conf_arg("token_exchange_endpoint")
    if exchange_token_endpoint then
      local error_status
      local opts = args.get_http_opts {
        method  = "POST",
        headers = {
          Authorization = "Bearer " .. tokens_encoded.access_token,
        },
      }

      if args.get_conf_arg("cache_token_exchange") then
        log("trying to exchange access token with caching enabled")
        token_exchanged, err, error_status = cache.token_exchange.load(
          tokens_encoded.access_token, exchange_token_endpoint, opts, ttl, true)

      else
        log("trying to exchange access token")
        token_exchanged, err, error_status = cache.token_exchange.load(
          tokens_encoded.access_token, exchange_token_endpoint, opts, ttl, false)
      end

      if not token_exchanged or error_status ~= 200 then
        if error_status == 401 then
          return unauthorized(
            iss,
            err or "exchange token endpoint returned unauthorized",
            session,
            anonymous,
            trusted_client)

        elseif error_status == 403 then
          return forbidden(
            iss,
            err or "exchange token endpoint returned forbidden",
            session,
            anonymous,
            trusted_client)

        else
          if err then
            return unexpected(trusted_client, err)

          else
            return unexpected(trusted_client, "exchange token endpoint returned ", error_status or "unknown")
          end
        end

      else
        log("exchanged access token successfully")
      end
    end
  end

  -- upstream and downstream headers
  do
    log("setting upstream and downstream headers")

    set_headers(args, "access_token",  token_exchanged or tokens_encoded.access_token)
    set_headers(args, "id_token",      tokens_encoded.id_token)
    set_headers(args, "refresh_token", tokens_encoded.refresh_token)
    set_headers(args, "introspection", token_introspected or function()
      return introspect_token(tokens_encoded.access_token, ttl)
    end)

    set_headers(args, "user_info", function()
      if args.get_conf_arg("cache_user_info") then
        return cache.userinfo.load(oic, tokens_encoded.access_token, ttl, true)

      else
        return cache.userinfo.load(oic, tokens_encoded.access_token, ttl, false)
      end
    end)

    set_headers(args, "access_token_jwk", function()
      if not tokens_decoded then
        tokens_decoded = oic.token:decode(tokens_encoded)
      end
      if tokens_decoded then
        local access_token = tokens_decoded.access_token
        if type(access_token) == "table" and access_token.jwk then
          return access_token.jwk
        end
      end
    end)

    set_headers(args, "id_token_jwk", function()
      if not tokens_decoded then
        tokens_decoded = oic.token:decode(tokens_encoded)
      end
      if tokens_decoded then
        local id_token = tokens_decoded.id_token
        if type(id_token) == "table" and id_token.jwk then
          return id_token.jwk
        end
      end
    end)
  end

  -- login actions
  do
    local login_action = args.get_conf_arg("login_action")
    if login_action == "response" or login_action == "redirect" then
      local has_login_method

      local login_methods = args.get_conf_arg("login_methods", { "authorization_code" })
      for _, login_method in ipairs(login_methods) do
        if auth_method == login_method then
          has_login_method = true
          break
        end
      end

      if has_login_method then
        if login_action == "response" then
          local login_response = {}

          local login_tokens = args.get_conf_arg("login_tokens")
          if login_tokens then
            log("adding login tokens to response")
            for _, name in ipairs(login_tokens) do
              if tokens_encoded[name] then
                login_response[name] = tokens_encoded[name]
              end
            end
          end

          log("login with response login action")
          return success(login_response)

        elseif login_action == "redirect" then
          if trusted_client.login_redirect_uri then
            local u = { trusted_client.login_redirect_uri }
            local i = 2

            local login_tokens = args.get_conf_arg("login_tokens")
            if login_tokens then
              log("adding login tokens to redirect uri")

              local login_redirect_mode   = args.get_conf_arg("login_redirect_mode", "fragment")
              local redirect_params_added = false

              if login_redirect_mode == "query" then
                if find(u[1], "?", 1, true) then
                  redirect_params_added = true
                end

              else
                if find(u[1], "#", 1, true) then
                  redirect_params_added = true
                end
              end

              for _, name in ipairs(login_tokens) do
                if tokens_encoded[name] then
                  if not redirect_params_added then
                    if login_redirect_mode == "query" then
                      u[i] = "?"

                    else
                      u[i] = "#"
                    end

                    redirect_params_added = true

                  else
                    u[i] = "&"
                  end

                  u[i+1] = name
                  u[i+2] = "="
                  u[i+3] = tokens_encoded[name]
                  i=i+4
                end
              end
            end

            no_cache_headers()

            log("login with redirect login action")
            return redirect(concat(u))
          end
        end
      end
    end
  end

  log("proxying to upstream")
end


OICHandler.PRIORITY = 1000
OICHandler.VERSION  = cache.version


return OICHandler
