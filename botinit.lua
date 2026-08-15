local carrion 	= require "lib.carrion"
local helpers 	= require "lib.helpers"
local ser		= require "lib.serialize"
local fs		= require "lib.fs"

local botlog = Logger:spec("fmk startup")

local roomname			= "chan-fuck-marry-kill@conference.carrion.chat"
local character_addr	= "https://carrion.chat/character/"
local botname			= "Fumaki"
local fmktabname		= "FMK"

local bropen			= "%["
local brclose			= "%]"
local spintimemins		= 5
local spintimesecs		= 60 * spintimemins

local tprint = helpers.tprint

local savepath = fs.join(carrion.BasePath, "fmksave.lua")

local rollpatterns = {
	"^.-[rR]+.-[oO]+.-[lL]+.-",
	"^.-[sS]+.-[pP]+.-[iIeE ]+.-[nN]+.-",
	"^.-[bB]+.-[oO]+.-[tT]+.-[lL]+.-[eE]+.-",
}

local statpattern = "^.-[sS]+.-[tT]+.-[aA]+.-[tT]+.-[sS]+.-"

local responsepattern = "^.-([fFmMkKpP]).-[ %,]+([fFmMkKpP]).-[ %,]+([fFmMkKpP]).-"
local catchallresponsepattern = "^.-([fFmMkKpP]).-([fFmMkKpP]).-([fFmMkKpP]).-"
local passpattern = "^.-[pP]+[aA]+[sS]+.-"
local globalpattern = "^.-[gG]+.-[lL]+.-[oO]+.-[bB]+.-[aA]+.-[lL]+.-"

local excludepattern = "^.-ignoreme.-"
local includepattern = "^.-includeme.-"

local registerpattern = "^.-regalt[ %,]+(.+)"
local unregisterpattern = "^.-unregalt[ %,]+(.+)"
local nl = "</br>"

---@alias AltRegResult
---|"failed"
---|"registered"
---|"confirmed"
---|"removed"

local answers = {
	f = "Fuck";
	m = "Marry";
	k = "Kill/Pass";
}

---@class FMKScore
local FMKScore = {
	f	= 0;
	m	= 0;
	k	= 0;
}
function FMKScore:new()
	return {
		f	= 0;
		m	= 0;
		k	= 0;
	}
end

---@class FMKSave
local FMKSave = {
	exceptions	= nil;	---@type integer[]
	scores		= nil;	---@type table<integer, FMKScore>
	banned		= nil;	---@type integer[]
	alts		= nil;	---@type table<integer, table<integer, boolean>>
}
function FMKSave:new()
	return setmetatable({
		exceptions	= {};
		scores		= {};
		banned		= {};
	}, { __index = self })
end

---@class Fumaki : BotIdentity, CarrionSSEEvents
local Fumaki = {
	save		= nil;	---@type FMKSave
	tab			= nil;	---@type string
	spinner		= nil;	---@type channeluser?
	spintimerem	= 0;
	options		= nil;	---@type integer[]
}

function Fumaki:postlogin()
	self:request(
		carrion.Api.presence.subscribe,
		carrion:makehttpcontent {
			rooms = {
				roomname,
			}
		}
	)
end

function Fumaki:getfmktab()
	if not self.tab then
		local tabsres = self:request(carrion.Api.channels.gettabs(roomname)):getbodytable()
		if not tabsres then
			self.log:warning("error finding fmk tab")
			return "general"
		end

		for _, tab in ipairs(tabsres.tabs) do
			if tab.title == fmktabname then
				self.tab = tab.tab_id
				break
			end
		end
	end
	return self.tab
end

function Fumaki:loaddata()
	self.log:debug("loading...")
	local res, _ = ser.loadFromFile(savepath)
	self.save = setmetatable(res or FMKSave:new(), { __index = FMKSave })
	self.save.alts = self.save.alts or {}

	-- helpers.tprint(self.save)
end

function Fumaki:savedata()
	ser.saveToFile(self.save, savepath)
	self.log:debug("saving...")
end

function Fumaki:update(dt)
	if self.spinner then
		self.spintimerem = (self.spintimerem or 0) - dt

		if self.spintimerem <= 0 then
			self:sendmessage(("%s missed their chance. Next!"):format(self.spinner.name))
			self.spinner = nil
		end
	end
end

function Fumaki:shutdown()
	self:savedata()
	self:request(carrion.Api.presence.disconnect)
end

function Fumaki:sendmessage(body, respondee, tab)
	local reqcontent = {
		body	= body;
		tab_id	= tab or self:getfmktab();
	}
	self.log:infoF("sending message '%s'", body)
	self:request(carrion.Api.channels.send(roomname), carrion:makehttpcontent(reqcontent))
end

---@param data sse.EventData.channel_message
function Fumaki:dofmk(data)
	if table.getIndex(self.save.banned, data.sender.id) ~= 0 then
		self.log:debug("banned user blocked from spinning")
		return
	end
	local function respond(body)
		-- self.log:debug(("responding... (%s)"):format(body))
		self:sendmessage(body)
	end
	if self.spinner then
		if self.spinner.id == data.sender.id then
			return
		end
		respond(("Be patient, %s is still deciding! (%ss remain)"):format(
			self.spinner.name,
			tostring(helpers.round(self.spintimerem)))
		)
		return
	end
	self.spinner = data.sender
	self.spintimerem = spintimesecs
	self.log:debug("attempting a spin...")

	local participant_ids
	if false --[[data.body:match(globalpattern)]] then	--- not good, janitors said no!
		participant_ids = table.map(carrion.Users, function (k, v)
			return k
		end)
	else
		local function noworky()
			self:sendmessage("Uh, there was some sort of problem. Blame my creator. Next spin is free again.")
		end
		local users_res = self:request(carrion.Api.room.getusers(roomname))
		local users_t = users_res:getbodytable()
		if not users_res then
			self.log:errorF("unable to get room users")
			self.spinner = nil
			noworky()
			return
		end
		local occupants = users_t and users_t.occupants ---@type Carrion.CharName[]?
		if not occupants then
			self.log:errorF("unable to get room users")
			self.spinner = nil
			noworky()
			return
		end

		participant_ids = table.map(occupants, function (_, v)
			return carrion.UserIDMap[v]
		end)
	end

	if love.math.random(0, 80) < 69 then
		table.removeItem(participant_ids, Fumaki.id)
	end
	table.removeItem(participant_ids, data.sender.id)
	local altlist = self.save.alts[data.sender.id]
	if altlist then
		for key, value in pairs(altlist) do
			if value then
				table.removeItem(participant_ids, key)
			end
		end
	end
	local particip_count = #participant_ids

	for _, id in ipairs(self.save.exceptions) do
		table.removeItem(participant_ids, id)
		particip_count = particip_count - 1
	end
	-- helpers.tprint(data)
	-- helpers.tprint(occupants)
	local picked_user_names = {}
	local option_ids = {}
	while #picked_user_names < 3 do
		if particip_count <= 0 then
			respond("Well, there's not enough people around for this...")
			self.spinner = nil
			return
		end

		local i = love.math.random(1, particip_count)
		local user_id = participant_ids[i]
		local user = carrion.Users[user_id]

		if not user then
			self.log:errorF("tried to take invalid participant: %s %s", tostring(i))
			goto continue
		end

		particip_count = particip_count - 1
		table.removeItem(participant_ids, user.id)
		if user.is_private == nil then
			local bulkres = self:request(carrion.Api.characters.bulk, carrion:makehttpcontent {
				names = {
					user.name
				}
			}):getbodytable()
			if not bulkres then
				goto continue
			end
			user.is_private = bulkres.profiles ~= nil and bulkres.profiles[user.name] ~= nil
		end
		if user.is_private then
			goto continue
		end
		-- print("num res:", #results, "index:", i, "user:", user)
		-- print(table.getIndex(self.exceptions, user) == 0)
		-- print(user, "==", data.sender.name, user == data.sender.name)
		table.insert(picked_user_names, user.name)
		table.insert(option_ids, user.id)

	    ::continue::
	end

	local res_body = ("Okay %s, you have %s minutes to choose your picks! Ping me here again with a valid pick, check my profile if you're unsure.%s"):format(data.sender.name, tostring(spintimemins), nl)
	for _, user in ipairs(picked_user_names) do
		res_body = ("%s[%s](%s%s)"):format(res_body, user, character_addr, helpers.urlencode(user))
		res_body = res_body..nl
	end

	self.options = option_ids
	respond(res_body)
	-- math.random(1, #user)
end

---@param data sse.EventData.channel_message
function Fumaki:tryextractresponse(data)
	self.log:debug("attempting response extraction...")
	if self.spinner.id ~= data.sender.id then
		self:sendmessage("It's not your turn!", data.sender)
		return
	end
	local selfname = ("?%s%s%s"):format(bropen, self.name, brclose)
	local message = data.body:sub(selfname:len() - 1)

	local choices = {}	---@type table<string, integer>
	local doubles = {}
	local function evaluate()
		self.log:debug("evaluating...")
		local succ = true
		local reasons = {}

		for answer, _ in pairs(doubles) do
			self.log:debugF("found double for %s", answer)
			succ = false
			table.insert(reasons, ("You picked twice for %s!"):format(answers[answer]))
		end
		for answer, readable in ipairs(answers) do
			if not choices[answer] then
				self.log:debugF("missing choice for %s", answer)
				succ = false
				table.insert(reasons, ("You don't have a choice for %s."):format(readable))
			end
		end

		return succ, reasons
	end

	local function match_pattern(pattern)
		self.log:debugF("matching. message: '%s', pattern '%s'...", message, pattern)
		local user_i = 1
		local match_count = 0
		local captures = {message:match(pattern)}
		for _, w in pairs(captures) do
			match_count = match_count + 1
			local entry, _ = w:lower():gsub("p", "k")
			self.log:debugF("match %i: %s; entry: '%s'", match_count, w, entry)
			if choices[entry] then
				doubles[entry] = true
			end
			choices[entry] = self.options[user_i]
			user_i = user_i + 1
		end

		return match_count == 3
	end

	for _, pattern in ipairs({ responsepattern, catchallresponsepattern }) do
		local match_succ = match_pattern(pattern)
		if match_succ then
			local succ, reasons = evaluate()
			if succ then
				for key, value in pairs(choices) do
					if not self.save.scores[value] then
						self.log:debugF("making new scores for user id %i", value)
						self.save.scores[value] = FMKScore:new()
					end
					local scores = self.save.scores[value]
					scores[key] = scores[key] + 1
				end
				self:sendmessage("👍")
				self.spinner = nil
			else
				local response = "You messed up;"..nl
				for _, reason in ipairs(reasons) do
					response = response..reason..nl
				end
				self:sendmessage(response)
			end
			return
		end
	end

	if message:match(passpattern) then
		self:sendmessage("Passing is not an option, it's not in the spirit of the game. Being faced with new faces is part of the game too.", data.sender)
		return
	end

	self:sendmessage("No idea what to do with your response, refer to my profile for valid answers!")
end

local probtexts = {
	"...I have literally no idea what you mean.",
	"We do not care.",
	"Something stink in here, or is that just me?",
	"Nuh uh.",
	"Say please.",
	"You're not trying hard enough.",
	"Calm down.",
	"/me is in the process of checking out her stopwatch. \"Huh, you're talking to me?!\"",
	"Just. No.",
	"Rude!",
	"/me shakes her head.",
	"/me wobbles her hand, \"Ehhhhh...\"",
	"I think I had a stroke trying to comprehend that.",
}
---@param data sse.EventData.channel_message
function Fumaki:nounderstand(data)
	self:sendmessage(probtexts[love.math.random(1, #probtexts)], data.sender, data.tab_id)
end

do --- sse
	---@param data sse.EventData.channel_message
	function Fumaki:channel_message(data)
		self.log:debug("got a message...")
		local pattern = ("^?%s%s%s"):format(bropen, self.name, brclose)
		local message = data.body
		if not message:match(pattern) then
			self.log:debug("we do not care")
			--- we dont care
			return
		end

		self.log:infoF("received pinging message '%s'", message)

		if message:match(excludepattern) then
			if table.getIndex(self.save.exceptions, data.sender.id) ~= 0 then
				self:sendmessage("You're already excluded from rolls.", data.sender, data.tab_id)
				return
			end
			table.insert(self.save.exceptions, data.sender.id)
			self:sendmessage("Very well, you wont appear in rolls from now on.", data.sender, data.tab_id)
			return
		elseif message:match(includepattern) then
			local succ = table.removeall(self.save.exceptions, data.sender.id)
			self:sendmessage(succ and "Alright, you're back in!" or "You're not even excluded...", data.sender, data.tab_id)
			return
		end

		do
			local function _getaltlist(id)
				if not self.save.alts[id] then
					self.save.alts[id] = {}
				end
				return self.save.alts[id]
			end
			local reg_res = message:match(registerpattern)
			local unreg_res = message:match(unregisterpattern)
			if reg_res or unreg_res then
				local is_reg = unreg_res == nil
				local capt = reg_res or unreg_res
				local id = tonumber(capt)
				local name = capt

				local datares;
				local errs = {}
				for _, val in pairs({id, name}) do
					local ok, res = pcall(function ()
						return self:request(carrion.Api.characters.byident(val)):getbodytable()
					end)
					if ok and res then
						datares = res
						break
					else
						table.insert(errs, {val, res})
					end
				end

				if not datares then
					self:sendmessage("I can't find a user with that Name/ID.", data.sender, data.tab_id)
					for _, value in pairs(errs) do
						self.log:debug(("Error in getting user with ident '%s': '%s'"):format(tostring(value[1]), tostring(value[2])))
					end
					return
				end

				local alt_list = _getaltlist(data.sender.id)
				local rev_list = _getaltlist(datares.id)
				local res = "failed" ---@type AltRegResult
				local error = "Nothing…?"

				if is_reg then
					if alt_list[datares.id] == nil then
						alt_list[datares.id] = false
						rev_list[data.sender.id] = false
						res = "registered"
					elseif alt_list[datares.id] then
						error = "Character is already a confirmed alt."
						res = "failed"
					elseif rev_list[data.sender.id] ~= nil then
						alt_list[datares.id] = true
						rev_list[data.sender.id] = true
						res = "confirmed"
					end
				else
					local succ = table.contains(alt_list, datares.id) or table.contains(rev_list, data.sender.id)
					if not succ then
						error = "Character is not registered as an alt."
					end
					alt_list[datares.id] = nil
					rev_list[data.sender.id] = nil
					res = succ and "removed" or "failed"
				end

				if res == "registered" then
					self:sendmessage(("Alright, %s is penciled in as your alt. Run the command with your Name/ID on them to confirm."):format(datares.name), data.sender, data.tab_id)
					return
				elseif res =="confirmed" then
					self:sendmessage(("Alright, %s is confirmed in as your alt, and won't appear in your rolls (and vice versa)."):format(datares.name), data.sender, data.tab_id)
					return
				elseif res == "removed" then
					self:sendmessage(("Alright, %s is removed as your alt."):format(datares.name), data.sender, data.tab_id)
					return
				elseif res =="failed" then
					self:sendmessage(("Something didn't work here: %s"):format(error), data.sender, data.tab_id)
					return
				end
			end
		end

		if data.tab_id == self:getfmktab() then
			for _, pat in ipairs(rollpatterns) do
				if message:match(pat) then
					self:dofmk(data)
					return
				end
			end
			if self.spinner then
				self:tryextractresponse(data)
				return
			end
		end

		if message:match(statpattern) then
			self.log:debugF("getting stats for %i", data.sender.id)
			local stats = self.save.scores[data.sender.id]
			if not stats then
				self:sendmessage("You haven't been spun yet!", data.sender, data.tab_id)
				return
			end
			local rollres = ""
			for key, readable in pairs(answers) do
				rollres = ("%s %s: %s"):format(rollres, readable, tostring(stats[key]))
			end
			self:sendmessage(("Alright, here;%s.%sRemember not to take things too seriously, it's just a game!"):format(rollres,  nl), data.sender, data.tab_id)
			return
		end

		self:nounderstand(data)
	end
end

---@param token	string
---@param arg	table
return function (token, arg)
	botlog:info("FMK bot starting")

	local fumaki = carrion.BotIdentity:create(botname, token, carrion, Fumaki)

	fumaki:loaddata()
	fumaki:login()

	fumaki:heartbeat()
end

