-- Link.lua
-- Reads a Wowhead talent calculator link, such as
--   https://www.wowhead.com/forever/talent-calc/mage/vkndmh2502...-550000002-003_t0/0A2c0bbbGD...
--
-- After the class comes the finished build: a few letters, then each tree's final talent
-- ranks, one digit per talent, trees separated by "-" and trailing zeros left out. Talents
-- are counted left to right along each row, rows top to bottom.
--
-- The last part is the order the points go in. A digit switches tree (0 is the first); a
-- lowercase letter puts one point in that talent; an uppercase letter fills the talent to
-- its final rank in the build. Letters count talents from a, skipping i, l, o and u.

local _, ns = ...

local Link = {}
ns.Link = Link

local LETTERS = "abcdefghjkmnpqrstvwxyz"
local MAX_TREES = 3

-- Returns { class, trees = { { rank per talent } x3 }, steps = { { tree, index, rank } } },
-- with trees and talents counted from 1; or nil and why not.
function Link.Parse(text)
	text = strtrim(text or "")
	local class, build, order = text:match("talent%-calc/(%a+)/([^/?#]+)/([^/?#]+)")
	if not class then
		return nil, "that isn't a Wowhead talent calculator link with a talent order in it"
	end

	local trees = {}
	local digits = build:match("^%a*([%d%-]*)")
	for part in (digits .. "-"):gmatch("(%d*)%-") do
		local ranks = {}
		for d in part:gmatch("%d") do
			ranks[#ranks + 1] = tonumber(d)
		end
		trees[#trees + 1] = ranks
	end
	if #trees > MAX_TREES then
		return nil, "the link has more than three talent trees"
	end
	while #trees < MAX_TREES do
		trees[#trees + 1] = {}
	end

	local steps, reached = {}, { {}, {}, {} }
	local tree = 1
	for ch in order:gmatch(".") do
		local digit = tonumber(ch)
		if digit then
			tree = digit + 1
			if tree > MAX_TREES then
				return nil, "the talent order names a tree the build doesn't have"
			end
		else
			local index = LETTERS:find(ch:lower(), 1, true)
			if not index then
				return nil, "the talent order has a character it shouldn't: " .. ch
			end
			local final = trees[tree][index] or 0
			local rank = reached[tree][index] or 0
			local points = ch == ch:lower() and 1 or final - rank
			if points < 1 or rank + points > final then
				return nil, "the talent order doesn't add up to the build"
			end
			for _ = 1, points do
				rank = rank + 1
				steps[#steps + 1] = { tree = tree, index = index, rank = rank }
			end
			reached[tree][index] = rank
		end
	end

	for t, ranks in ipairs(trees) do
		for index, final in ipairs(ranks) do
			if (reached[t][index] or 0) ~= final then
				return nil, "the talent order stops before the build is finished"
			end
		end
	end
	if #steps == 0 then
		return nil, "the link has no talent order in it"
	end
	return { class = class:lower(), trees = trees, steps = steps }
end
