-- Parses Wowhead talent-calculator links with TalentPath's Link.lua and checks the steps.
-- The expected steps were checked by hand against Wowhead's own order lists.
local path = ...
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local ns = {}
assert(loadfile(path))("TalentPath", ns)

local failed = false
local function Steps(url)
  local b, err = ns.Link.Parse(url)
  if not b then return nil, err end
  local line = {}
  for i, s in ipairs(b.steps) do line[#line + 1] = (i + 9) .. ":" .. s.tree .. "/" .. s.index .. "r" .. s.rank end
  return b.class, table.concat(line, " "), #b.steps
end
local function Expect(label, ok)
  print((ok and "PASS " or "FAIL ") .. label)
  if not ok then failed = true end
end

local class, steps, n = Steps("https://www.wowhead.com/forever/talent-calc/mage/vkndmh250205223100311531-550000002-003_t0/0A2c0bbbGDbkbfffqffP2c0SrJT1BA0v2c0H1J")
Expect("mage link: 51 steps", class == "mage" and n == 51)
Expect("mage link: order", steps and steps:find("^10:1/1r1 11:1/1r2 12:3/3r1 13:1/2r1") and steps:find("59:2/9r1 60:2/9r2$"))
class, steps, n = Steps("https://www.wowhead.com/forever/talent-calc/paladin/vkndmh050050002-503-05233011201301351_t0/2BCEhJddmNdRqgSt0BEJ1AC")
Expect("paladin link: 51 steps", class == "paladin" and n == 51)
Expect("paladin link: order", steps and steps:find("^10:3/2r1 11:3/2r2") and steps:find("58:2/3r1 59:2/3r2 60:2/3r3$"))
Expect("no order: error", Steps("https://www.wowhead.com/forever/talent-calc/mage/vkndmh250205223100311531-550000002-003_t0") == nil)
Expect("order stops early: error", Steps("https://www.wowhead.com/forever/talent-calc/mage/vkndmh250205223100311531-550000002-003_t0/0A2c0bbbGD") == nil)
local _, err = Steps("  https://www.wowhead.com/forever/talent-calc/mage/vkndmh-503_t0/1A  ")
Expect("spaces around a link are trimmed", type(err) == "string" and err:find("stops before") ~= nil)
print(failed and "FAILED" or "ok")
