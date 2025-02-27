TYPE_INSTANCE = 45
simple_class = simple_class or {}
simple_class.classes = simple_class.classes or {}
function simple_class.is_class(val)
	return istable(val) and string.match(tostring(val), "class%[(.-)%]")
end

function simple_class.is_instance(val)
	return istable(val) and string.match(tostring(val), "instance%[(.-)%]")
end

function simple_class.is_serialized_instance(val)
	return istable(val) and val.__is_instance and isstring(val.__class)
end

function simple_class:get_class(name)
	return name and self.classes[name]
end

local class_meta = {}
class_meta.__index = class_meta
function class_meta:__call(name, parents)
	if not name then
		error("The class needs to be given a name.")
	end
	parents = simple_class.is_class(parents) and { parents } or parents
	local new_class = setmetatable({
		__name = name,
		__parents = parents,
		__is_class = true,
	}, {
		__index = parents and function(tbl, key)
			for _, parent in ipairs(parents) do
				local val = parent[key]
				if val then
					return val
				end
			end
		end or self,
		__call = self.__call,
		__tostring = function()
			return "class[" .. name .. "]"
		end,
	})

	new_class.__index = new_class
	simple_class.classes[name] = new_class
	return new_class
end

function class_meta:extends(name)
	return class(self, name)
end

function class_meta:get_parents()
	return self.__parents or {}
end

function class_meta:setter(key)
	self["set_" .. key] = function(this, new_val)
		this[key] = new_val
	end
end

function class_meta:getter(key)
	self["get_" .. key] = function(this)
		return this[key]
	end
end

function class_meta:etter(key)
	self:setter(key)
	self:getter(key)
end

function class_meta:get_name()
	return self.__name
end

function class_meta:get_constructor()
	return self.__constructor
end

function class_meta:super(instance, props)
	props = props or {}
	if not instance then
		return
	end
	local parents = self:get_parents()
	if parents then
		for _, parent in ipairs(parents) do
			local constructor = parent:get_constructor()
			if not constructor then
				return
			end
			constructor(instance, props, parent)
		end
	end
end

local instance_meta = {}
function instance_meta:get_class()
	return self.__class
end

function instance_meta:serialize()
	return simple_class.Serializer():_serialize(self)
end

function instance_meta:instanceof(other_class)
	local visited = {}
	local queue = { self:get_class() }
	while #queue > 0 do
		local current = table.remove(queue, 1)
		if visited[current] then
			continue
		end
		visited[current] = true
		if current == other_class then
			return true
		end
		local parents = current:get_parents()
		if parents then
			for _, parent in ipairs(parents) do
				if not visited[parent] then
					table.insert(queue, parent)
				end
			end
		end
	end
	return false
end

local function random_hex(bits)
	return string.format("%0" .. (bits / 4) .. "x", math.random(0, 2 ^ bits - 1))
end

function simple_class.generate_uuid()
	return string.format("%s-%s-%s-%s", random_hex(48), random_hex(32), random_hex(16), random_hex(12))
end

function simple_class.is_uuid(uuid)
	if type(uuid) ~= "string" then
		return false
	end
	local pattern = "^"
		.. string.rep("[0-9a-fA-F]", 12)
		.. "%-"
		.. string.rep("[0-9a-fA-F]", 8)
		.. "%-"
		.. string.rep("[0-9a-fA-F]", 4)
		.. "%-"
		.. string.rep("[0-9a-fA-F]", 3)
		.. "$"
	return uuid:match(pattern) ~= nil
end

class = setmetatable({}, class_meta)
function class:__call(props)
	props = props or {}
	local copy_instance_meta = table.Copy(instance_meta)
	copy_instance_meta.__index = copy_instance_meta
	local instance = setmetatable({
		__id = simple_class.generate_uuid(),
		__class = self,
		__is_instance = true,
	}, {
		__index = setmetatable(copy_instance_meta, self),
		__tostring = function()
			return "instance[" .. self:get_name() .. "]"
		end,
	})

	local constructor = self:get_constructor()
	if constructor then
		constructor(instance, props, self)
	end
	return instance
end

function net.WriteInstance(instance)
	if not simple_class.is_instance(instance) then
		return
	end
	net.WriteTable(instance:serialize())
end

function net.ReadInstance()
	return simple_class.Serializer():deserialize(net.ReadTable())
end

net.WriteVars[TYPE_INSTANCE] = function(t, v)
	net.WriteUInt(t, 8)
	net.WriteInstance(v)
end

net.ReadVars[TYPE_INSTANCE] = function(t, v)
	return net.ReadInstance()
end
function net.WriteType(v)
	local typeid = nil
	if qanon.is_color(v) then
		typeid = TYPE_COLOR
	elseif simple_class.is_instance(v) then
		typeid = TYPE_INSTANCE
	else
		typeid = TypeID(v)
	end

	local wv = net.WriteVars[typeid]
	if wv then
		return wv(typeid, v)
	end
	error("net.WriteType: Couldn't write " .. type(v) .. " (type " .. typeid .. ")")
end

local Serializer = class("Serializer")
function Serializer:__constructor()
	self.instances = {}
end

local not_valid_types = {
	["function"] = true,
	["thread"] = true,
	["userdata"] = true,
}

function Serializer:_serialize(tbl)
	local tbl_copy = {}
	if simple_class.is_instance(tbl) then
		self.instances[tbl.__id] = true
		tbl_copy.__class = tbl:get_class():get_name()
	end

	for k, v in pairs(tbl) do
		local t = type(v)
		if not_valid_types[t] then
			continue
		elseif t == "table" then
			if k == "__class" then
				continue
			end
			if simple_class.is_instance(v) and self.instances[v.__id] then
				tbl_copy[k] = v.__id
			else
				tbl_copy[k] = self:_serialize(v)
			end
		else
			tbl_copy[k] = v
		end
	end
	return tbl_copy
end

function Serializer:deserialize(tbl)
	local copy_tbl = {}
	if simple_class.is_serialized_instance(tbl) then
		local instance_class = simple_class:get_class(tbl.__class)
		if instance_class then
			copy_tbl = instance_class(tbl)
			self.instances[tbl.__id] = copy_tbl
		end
	end

	for k, v in pairs(tbl) do
		if k == "__class" then
			continue
		end
		if simple_class.is_uuid(v) and k ~= "__id" then
			copy_tbl[k] = self.instances[v]
		elseif simple_class.is_serialized_instance(v) or istable(v) then
			copy_tbl[k] = self:deserialize(v)
		else
			copy_tbl[k] = v
		end
	end
	return copy_tbl
end

simple_class.Serializer = Serializer
