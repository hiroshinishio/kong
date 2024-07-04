local _M = {}
local _MT = { __index = _M, }


local hooks = require("kong.clustering.services.sync.hooks")
local strategy = require("kong.clustering.services.sync.strategies.postgres")
local methods = require("kong.clustering.services.sync.methods")


function _M.new(db)
  local strategy = strategy.new(db)

  local self = {
    db = db,
    strategy = strategy,
    hooks = hooks.new(strategy),
    methods = methods.new(strategy),
  }

  return setmetatable(self, _MT)
end


function _M:init(manager, is_cp)
  self.hooks:register_dao_hooks(is_cp)
  self.methods:init(manager, is_cp)
end


function _M:init_worker_dp()
  if ngx.worker.id() == 0 then
    assert(self.methods:sync_once(5))
  end
end


return _M
