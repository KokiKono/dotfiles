local wezterm = require 'wezterm'
local config = wezterm.config_builder()

-- ============================================================
-- Plugins: load all .lua files from plugins.d/
-- ============================================================
for _, file in ipairs(wezterm.glob(wezterm.config_dir .. '/plugins.d/*.lua')) do
  dofile(file)
end

return config
