-- Util.lua
-- Helpers shared by the message layer and the link: printing, names, hashing, packing and
-- table diffs.

local _, ns = ...

local Util = {}
ns.Util = Util

Util.PREFIX = "AcctLink"

function Util.Print(text)
	print("|cff33ff99AccountLink:|r " .. text)
end

function Util.Debug(text)
	if AccountLinkDB and AccountLinkDB.debug then
		Util.Print("|cff999999" .. text .. "|r")
	end
end

-- On Forever, chat lockdown can hand out hidden values; testing or comparing one is an error.
function Util.IsHidden(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

---------------------------------------------------------------------------------------------
-- Names. Forever names are unique per region and come as "First Surname"; whispers need both.

local function SurnameSeparator()
	local consts = Constants and Constants.CharacterNameSeparatorConsts
	local separator = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR
	return type(separator) == "string" and separator ~= "" and separator or " "
end

-- UnitName returns first name and surname separately.
function Util.FullUnitName(unit)
	local first, surname = UnitName(unit)
	if Util.IsHidden(first) or Util.IsHidden(surname) or not first then
		return nil
	end
	if surname and surname ~= "" then
		return first .. SurnameSeparator() .. surname
	end
	return first
end

-- One spelling per character for comparisons: lower case, without a "-Realm" or "-Ruleset" ending.
function Util.Norm(name)
	return (name:gsub("%-[^%-]*$", "")):lower()
end

-- Group members whose first or full name matches, completed to the full name a whisper needs.
function Util.CompleteName(name)
	local wanted = name:lower()
	for i = 1, GetNumSubgroupMembers() do
		local full = Util.FullUnitName("party" .. i)
		if full and (full:lower() == wanted or full:lower():match("^(%S+)") == wanted) then
			return full
		end
	end
	return name
end

---------------------------------------------------------------------------------------------
-- Randomness and hashing. Forever's API has no hash function, so this is a small one: two
-- polynomial hashes kept below 2^31, so every step stays exact in Lua numbers. Not
-- cryptographic, but enough for checksums and for proving the pairing secret without sending it.

local ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789"

function Util.RandomString(length)
	local chars = {}
	for i = 1, length do
		local n = math.random(#ALPHABET)
		chars[i] = ALPHABET:sub(n, n)
	end
	return table.concat(chars)
end

function Util.Hash(text)
	local a, b = 7, 131
	for i = 1, #text do
		local c = text:byte(i)
		a = (a * 31 + c) % 2147483647
		b = (b * 37 + c) % 2147483629
	end
	return a .. "." .. b
end

local function SortKeys(a, b)
	local ta, tb = type(a), type(b)
	if ta ~= tb then
		return ta < tb
	elseif ta == "number" or ta == "string" then
		return a < b
	end
	return tostring(a) < tostring(b)
end

-- The same hash for the same contents whatever order pairs() walks them in, so two clients can
-- tell whether their copies of a character's data match.
function Util.ContentHash(value)
	local parts = {}
	local function Walk(v)
		if type(v) == "table" then
			local keys = {}
			for k in pairs(v) do
				keys[#keys + 1] = k
			end
			table.sort(keys, SortKeys)
			parts[#parts + 1] = "{"
			for _, k in ipairs(keys) do
				parts[#parts + 1] = type(k):sub(1, 1) .. tostring(k) .. "="
				Walk(v[k])
				parts[#parts + 1] = ";"
			end
			parts[#parts + 1] = "}"
		else
			parts[#parts + 1] = type(v):sub(1, 1) .. tostring(v)
		end
	end
	Walk(value)
	return Util.Hash(table.concat(parts))
end

---------------------------------------------------------------------------------------------
-- Packing: tables to text that fits in addon messages, with the game's own tools.

function Util.Pack(value)
	local ok, raw = pcall(C_EncodingUtil.SerializeCBOR, value)
	if not ok or type(raw) ~= "string" then
		return nil
	end
	local compressed = C_EncodingUtil.CompressString(raw)
	return compressed and C_EncodingUtil.EncodeBase64(compressed)
end

function Util.Unpack(text)
	local compressed = C_EncodingUtil.DecodeBase64(text)
	local raw = compressed and C_EncodingUtil.DecompressString(compressed)
	if not raw then
		return nil
	end
	local ok, value = pcall(C_EncodingUtil.DeserializeCBOR, raw)
	if ok and type(value) == "table" then
		return value
	end
end

---------------------------------------------------------------------------------------------
-- Tables: copies, comparison, and the small change lists that keep a copy up to date.

function Util.Copy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = Util.Copy(v)
	end
	return copy
end

function Util.Equal(a, b)
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in pairs(a) do
		if not Util.Equal(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function HoldsTables(t)
	for _, v in pairs(t) do
		if type(v) == "table" then
			return true
		end
	end
	return false
end

-- The changes that turn old into new, as a list of { p = path, v = value } and { p = path, d = true }
-- (deleted). Tables holding other tables are walked into; tables of plain values, like one item
-- slot in Syndicator's data, are compared and replaced whole. Looting one item becomes a single
-- small change.
function Util.Diff(old, new)
	local changes = {}
	local path = {}
	local function Walk(o, n)
		for k, nv in pairs(n) do
			local ov = o[k]
			path[#path + 1] = k
			if type(nv) == "table" and type(ov) == "table" and HoldsTables(nv) then
				Walk(ov, nv)
			elseif not Util.Equal(ov, nv) then
				changes[#changes + 1] = { p = { unpack(path) }, v = Util.Copy(nv) }
			end
			path[#path] = nil
		end
		for k in pairs(o) do
			if n[k] == nil then
				path[#path + 1] = k
				changes[#changes + 1] = { p = { unpack(path) }, d = true }
				path[#path] = nil
			end
		end
	end
	Walk(old, new)
	return changes
end

function Util.Apply(root, changes)
	for _, change in ipairs(changes) do
		local path = change.p
		if type(path) == "table" and #path > 0 then
			local t = root
			for i = 1, #path - 1 do
				if type(t[path[i]]) ~= "table" then
					t[path[i]] = {}
				end
				t = t[path[i]]
			end
			if change.d then
				t[path[#path]] = nil
			else
				t[path[#path]] = change.v
			end
		end
	end
end
