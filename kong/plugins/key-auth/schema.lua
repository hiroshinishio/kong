-- This software is copyright Kong Inc. and its licensors.
-- Use of the software is subject to the agreement between your organization
-- and Kong Inc. If there is no such agreement, use is governed by and
-- subject to the terms of the Kong Master Software License Agreement found
-- at https://konghq.com/enterprisesoftwarelicense/.
-- [ END OF LICENSE 0867164ffc95e54f04670b5169c09574bdbd9bba ]

local typedefs = require "kong.db.schema.typedefs"


return {
  name = "key-auth",
  fields = {
    { consumer = typedefs.no_consumer },
    { protocols = typedefs.protocols_http_and_ws },
    { config = {
        type = "record",
        fields = {
          { key_names = {
              type = "array",
              required = true,
              elements = typedefs.header_name,
              default = { "apikey" },
          }, },
          { hide_credentials = { type = "boolean", required = true, default = false }, },
          { anonymous = { type = "string" }, },
          { key_in_header = { type = "boolean", required = true, default = true }, },
          { key_in_query = { type = "boolean", required = true, default = true }, },
          { key_in_body = { type = "boolean", required = true, default = false }, },
          { run_on_preflight = { type = "boolean", required = true, default = true }, },
        },
    }, },
  },
}
