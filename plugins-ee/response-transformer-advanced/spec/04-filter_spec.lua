-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local helpers = require "spec.helpers"

local strategies = helpers.all_strategies ~= nil and helpers.all_strategies or helpers.each_strategy

for _, strategy in strategies() do
  describe("Plugin: response-transformer-advanced (filter) [#" .. strategy .. "]", function()
    local proxy_client
    local db_strategy = strategy ~= "off" and strategy or nil

    lazy_setup(function()
      local bp = helpers.get_db_utils(db_strategy, nil, {
        "response-transformer-advanced",
      })


      local route1 = bp.routes:insert({
        hosts = { "response.com" },
      })

      local route2 = bp.routes:insert({
        hosts = { "response2.com" },
      })

      local route3 = bp.routes:insert({
        hosts = { "response3.com" },
      })

      bp.plugins:insert {
        route    = { id = route1.id },
        name     = "response-transformer-advanced",
        config   = {
          remove    = {
            headers = {"Access-Control-Allow-Origin"},
            json    = {"url"}
          }
        }
      }

      bp.plugins:insert {
        route    = { id = route2.id },
        name     = "response-transformer-advanced",
        config   = {
          replace = {
            json  = {"headers:/hello/world", "uri_args:this is a / test", "url:\"wot\""}
          }
        }
      }

      bp.plugins:insert {
        route    = { id = route3.id },
        name     = "response-transformer-advanced",
        config   = {
          remove = {
            json  = {"ip"}
          }
        }
      }

      bp.plugins:insert {
        route    = { id = route3.id },
        name     = "basic-auth",
      }

      assert(helpers.start_kong({
        database   = db_strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
        plugins    = "bundled, response-transformer-advanced"
      }))
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    before_each(function()
      proxy_client = helpers.proxy_client()
    end)

    after_each(function()
      if proxy_client then
        proxy_client:close()
      end
    end)

    describe("parameters", function()
      it("remove a parameter", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          headers = {
            host  = "response.com"
          }
        })
        assert.response(res).has.status(200)
        local json = assert.response(res).has.jsonbody()
        assert.is_nil(json.url)
      end)
      it("remove a header", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/response-headers",
          headers = {
            host  = "response.com"
          }
        })
        assert.response(res).has.status(200)
        assert.response(res).has.jsonbody()
        assert.response(res).has.no.header("acess-control-allow-origin")
      end)
      it("replace a body parameter on GET", function()
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          headers = {
            host  = "response2.com"
          }
        })
        assert.response(res).status(200)
        local json = assert.response(res).has.jsonbody()
        assert.equals([[/hello/world]], json.headers)
        assert.equals([["wot"]], json.url)
        assert.equals([[this is a / test]], json.uri_args)
      end)
    end)

    describe("regressions", function()
      it("does not throw an error when request was short-circuited in access phase", function()
        -- basic-auth and response-transformer applied to route makes request
        -- without credentials short-circuit before the response-transformer
        -- access handler gets a chance to be executed.
        --
        -- Regression for https://github.com/Kong/kong/issues/3521
        local res = assert(proxy_client:send {
          method  = "GET",
          path    = "/get",
          headers = {
            host  = "response3.com"
          }
        })

        assert.response(res).status(401)
      end)
    end)
  end)
end