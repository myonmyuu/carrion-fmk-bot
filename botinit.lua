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

local savepath = fs.join(carrion.BasePath, "fmksave.lua")

local rollpatterns = {
	"^.-[rR]+[oO]+[lL]+.-",
	"^.-[sS]+[pP]+[iIeE]+[eE]+[nN]+.-",
	"^.-[bB]+[oO]+[tT]+[lL]+[eE]+.-",
}

local statpattern = "^.-[sS]+[tT]+[aA]+[tT]+[sS]+.-"

local responsepattern = "^.-([fFmMkKpP]).-[ %,]([fFmMkKpP]).-[ %,]-([fFmMkKpP]).-"
local catchallresponsepattern = "^.-([fFmMkKpP]).-([fFmMkKpP]).-([fFmMkKpP]).-"

local excludepattern = "^.-ignoreme.-"
local includepattern = "^.-includeme.-"
local nl = "</br>"

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
	helpers.tprint(self.save)
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
end

function Fumaki:sendmessage(body, respondee, tab)
	local reqcontent = {
		body	= body;
		tab_id	= tab or self:getfmktab();
	}
	self:request(carrion.Api.channels.send(roomname), carrion:makehttpcontent(reqcontent))
end

---@param data sse.Event.channel_message
function Fumaki:dofmk(data)
	if table.getIndex(self.save.banned, data.sender.id) ~= 0 then
		self.log:debug("banned user blocked from spinning")
		return
	end
	local function respond(body)
		self.log:debug(("responding... (%s)"):format(body))
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

	local users_res = self:request(carrion.Api.room.getusers(roomname))
	local users_t = users_res:getbodytable()
	if not users_res then
		self.log:errorF("unable to get room users")
		self.spinner = nil
		return
	end
	local occupants = users_t and users_t.occupants ---@type string[]?
	if not occupants then
		self.log:errorF("unable to get room users")
		self.spinner = nil
		return
	end

	table.removeItem(occupants, data.sender.name)
	local occucount = #occupants
	local occupant_by_id = {}
	local occupant_ids = {}

	for _, name in ipairs(occupants) do
		local id_res = self:request(carrion.Api.characters.byname(name)):getbodytable()
		if id_res then
			occupant_by_id[id_res.id] = name
			table.insert(occupant_ids, id_res.id)
		end
	end
	for _, id in ipairs(self.save.exceptions) do
		table.removeItem(occupant_ids, id)
		occupant_by_id[id] = nil
		occucount = occucount - 1
	end
	-- helpers.tprint(data)
	-- helpers.tprint(occupants)
	local picked_user_names = {}
	local option_ids = {}
	while #picked_user_names < 3 do
		if #occupant_ids <= 0 then
			respond("Well, there's not enough people for this here...")
			self.spinner = nil
			return
		end

		local i = love.math.random(1, occucount)
		local user_id = occupant_ids[i]
		local user_name = occupant_by_id[user_id]
		-- print("num res:", #results, "index:", i, "user:", user)
		-- print(table.getIndex(self.exceptions, user) == 0)
		-- print(user, "==", data.sender.name, user == data.sender.name)
		table.insert(picked_user_names, user_name)
		table.insert(option_ids, user_id)
		table.removeItem(occupant_ids, user_id)
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

---@param data sse.Event.channel_message
function Fumaki:tryextractresponse(data)
	self.log:debug("attempting response extraction...")
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

	self:sendmessage("No idea what to do with your response, refer to my profile for valid answers!")
end

---@param data sse.Event.channel_message
function Fumaki:channel_message(data)
	self.log:debug("got a message...")
	local pattern = ("^?%s%s%s"):format(bropen, self.name, brclose)
	local message = data.body
	if not message:match(pattern) then
		self.log:debug("we do not care")
		--- we dont care
		return
	end

	if data.tab_id == self:getfmktab() then
		if self.spinner and self.spinner.id == data.sender.id then
			self:tryextractresponse(data)
		end
		for _, pat in ipairs(rollpatterns) do
			if message:match(pat) then
				self:dofmk(data)
				break
			end
		end
	end

	if message:match(excludepattern) then
		table.insert(self.save.exceptions, data.sender.id)
		self:sendmessage("Very well, you wont appear in rolls from now on.", data.sender, data.tab_id)
	elseif message:match(includepattern) then
		local succ = table.removeall(self.save.exceptions, data.sender.id)
		self:sendmessage(succ and "Alright, you're back in!" or "You're not even excluded...", data.sender, data.tab_id)
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
	end
	-- helpers.tprint(data)
end

---@param token	string
---@param arg	table
return function (token, arg)
	botlog:info("FMK bot starting")

	local fumaki = carrion.BotIdentity:create(botname, token, carrion, Fumaki)

	fumaki:loaddata()
	fumaki:login()

	local res = fumaki:request(
		carrion.Api.presence.subscribe,
		carrion:makehttpcontent {
			rooms = {
				roomname,
			}
		}
	)

	fumaki:heartbeat()
end

