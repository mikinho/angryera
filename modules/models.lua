-- -------------------------------------------------------------------------------
-- Angry Era: modules/models.lua
--
-- Page/category CRUD, history, navigation, display page selection.
-- -------------------------------------------------------------------------------

local _, app = ...
local AngryEra = app.AngryEra
local helpers = AngryEra.utils.helpers
local selectedLastValue = helpers.selectedLastValue
local tReverse = helpers.tReverse
local IsCategoryDescendant = helpers.IsCategoryDescendant
local ExtractAndValidateName = helpers.ExtractAndValidateName

local libC = app.libs.libC

--- Displays a page by its exact name.
-- @tparam string name Page name.
-- @treturn boolean|nil `true` when displayed, `false` when not found, or `nil` on permission failure.
function AngryEra:DisplayPageByName( name )
	for id, page in pairs(AngryAssign_Pages) do
		if page.Name == name then
			return self:DisplayPage( id )
		end
	end
	return false
end

--- Displays a page for the group and marks it updated.
-- Sends both page and display sync payloads.
-- @tparam number id Page id.
-- @treturn boolean|nil `true` on success, or `nil` when permission fails.
function AngryEra:DisplayPage( id )
	if not self:PermissionCheck() then
		return
	end

	self:TouchPage( id )
	self:SendPage( id, true )
	self:SendDisplay( id, true )

	if AngryAssign_State.displayed ~= id then
		AngryAssign_State.displayed = id
		AngryEra:UpdateDisplayed()
		AngryEra:ShowDisplay()
		AngryEra:UpdateTree()
		AngryEra:DisplayUpdateNotification()
	end

	return true
end

function AngryEra:CategoryUpdated(id)
	self:UpdateTree()
	self:UpdateDisplayed()
end

function AngryEra:PageUpdated(id)
	self:UpdateTree()
	self:UpdateDisplayed()
	local page = AngryAssign_Pages[id]
	if page then
		page.Updated = time()
		self:SendPage(id, true)
	end
end

-- ── Import Helper Functions ──────────────────────────────────────────────────

--- Returns the id of a page or category by exact name.
-- @tparam string name Entity name.
-- @tparam string type Either `"Page"` or `"Category"`.
-- @treturn number|nil Matching entity id.
function AngryEra:GetEntityByName(name, type)
	if type == "Page" then
		for id, page in pairs(AngryAssign_Pages) do
			if page.Name == name then
				return id
			end
		end
	elseif type == "Category" then
		for id, cat in pairs(AngryAssign_Categories) do
			if cat.Name == name then
				return id
			end
		end
	end
	return nil
end

--- Produces a unique name by appending ` (n)` suffixes when needed.
-- @tparam string name Base name.
-- @tparam string type Either `"Page"` or `"Category"`.
-- @treturn string Unique name.
function AngryEra:GetUniqueEntityName(name, type)
	local newName = name
	local n = 1
	while self:GetEntityByName(newName, type) do
		newName = string.format("%s (%d)", name, n)
		n = n + 1
	end
	return newName
end

--- Deletes all nested categories and pages under a category id.
-- @tparam number catId Category id to recursively clear.
function AngryEra:DeleteCategoryChildren(catId)
	-- Delete sub-categories recursively
	for id, cat in pairs(AngryAssign_Categories) do
		if cat.CategoryId == catId then
			self:DeleteCategoryChildren(id)
			AngryAssign_Categories[id] = nil
			if AngryAssign_State.tree.groups then
				AngryAssign_State.tree.groups[-id] = nil
			end
		end
	end
	-- Delete pages
	for id, page in pairs(AngryAssign_Pages) do
		if page.CategoryId == catId then
			AngryAssign_Pages[id] = nil
			if AngryAssign_State.displayed == id then
				self:ClearDisplayed()
			end
		end
	end
end

-- ----------------------------------
-- Performing changes functions --
-- ----------------------------------

function AngryEra:PrevPage()
	self:NextPage(true);
end

function AngryEra:NextPage(reverse)
	local page = AngryAssign_Pages[ AngryAssign_State.displayed ]
	if not page then
		return
	end
	if not page.CategoryId then
		return
	end

	local siblings = {}
	for _, p in pairs(AngryAssign_Pages) do
		if p.CategoryId and p.CategoryId == page.CategoryId then
			table.insert(siblings, p)
		end
	end

	-- Use the same sort order as the Tree
	table.sort(siblings, function(a, b)
		local ia = a.Index
		local ib = b.Index
		if ia and ib then
			if ia == ib then
				return a.Name < b.Name
			end
			return ia < ib
		elseif ia then return true
		elseif ib then return false
		else return a.Name < b.Name end
	end)

	for i, p in ipairs(siblings) do
		if p.Id == page.Id then
			local dest = siblings[reverse and (i - 1) or (i + 1)]
			if dest then
				self:DisplayPage(dest.Id)
			else
				self:Print(reverse and "Already at first page." or "Already at last page.")
			end
			return
		end
	end
end

function AngryEra:FirstPage()
	local page = AngryAssign_Pages[ AngryAssign_State.displayed ]
	if not page or not page.CategoryId then
		return
	end

	local siblings = {}
	for _, p in pairs(AngryAssign_Pages) do
		if p.CategoryId == page.CategoryId then
			table.insert(siblings, p)
		end
	end

	if #siblings == 0 then
		return
	end

	-- Use the same sort order as the Tree
	table.sort(siblings, function(a, b)
		local ia = a.Index
		local ib = b.Index
		if ia and ib then
			if ia == ib then
				return a.Name < b.Name
			end
			return ia < ib
		elseif ia then return true
		elseif ib then return false
		else return a.Name < b.Name end
	end)

	local firstSib = siblings[1]

	if page.Id == firstSib.Id then
		-- We are already on the first page. Snap back to the last selected page?
		local lastPage = self.lastNonFirstPageId and AngryAssign_Pages[self.lastNonFirstPageId]
		if lastPage and lastPage.CategoryId == page.CategoryId then
			self:DisplayPage(self.lastNonFirstPageId)
			self.lastNonFirstPageId = nil
		else
			self:Print("Already on the first page.")
		end
	else
		self.lastNonFirstPageId = page.Id
		self:DisplayPage(firstSib.Id)
	end
end

function AngryEra:SelectedId()
	return selectedLastValue( AngryAssign_State.tree.selected )
end

function AngryEra:SetSelectedId(selectedId)
	local page = AngryAssign_Pages[selectedId]
	if page then
		if page.CategoryId then
			local cat = AngryAssign_Categories[page.CategoryId]
			local path = { }
			while cat do
				table.insert(path, -cat.Id)
				if cat.CategoryId then
					cat = AngryAssign_Categories[cat.CategoryId]
				else
					cat = nil
				end
			end
			tReverse(path)
			table.insert(path, page.Id)
			self.window.tree:SelectByPath(unpack(path))
		else
			self.window.tree:SelectByValue(page.Id)
		end
	else
		self.window.tree:SetSelected()
	end
end

--- Returns a page by id or current selection.
-- @tparam[opt] number id Page id, defaults to selected id.
-- @treturn table|nil Page table.
function AngryEra:Get(id)
	if id == nil then
		id = self:SelectedId()
	end
	return AngryAssign_Pages[id]
end

--- Returns a category by id.
-- @tparam number id Category id.
-- @treturn table|nil Category table.
function AngryEra:GetCat(id)
	return AngryAssign_Categories[id]
end

--- Computes a stable FCS32 update hash for page identity/versioning.
-- @tparam string name Page name.
-- @tparam string contents Page contents.
-- @tparam[opt] string vars Page variable string.
-- @treturn string Hash string.
function AngryEra:Hash(name, contents, vars)
	local code = libC:fcs32init()
	code = libC:fcs32update(code, name)
	code = libC:fcs32update(code, "\n")
	code = libC:fcs32update(code, contents)
	if vars then
		code = libC:fcs32update(code, "\n")
		code = libC:fcs32update(code, vars)
	end
	return libC:fcs32final(code)
end

--- Creates a page and syncs it to the group.
-- @tparam string|table nameOrFrame Name text or popup/editbox frame.
-- @tparam[opt=""] string content Initial page content.
-- @tparam[opt] number categoryId Parent category id.
-- @tparam[opt] number index Sort index override.
-- @treturn boolean ok
-- @treturn string|nil err Error message on failure.
-- @treturn number|nil id New page id on success.
function AngryEra:CreatePage(nameOrFrame, content, categoryId, index)
	-- Check Permissions first
	if not self:PermissionCheck() then
		return false, "Permission denied."
	end

	-- Validate and Clean Input
	local name, err = ExtractAndValidateName(nameOrFrame)
	if not name then
		return false, err
	end

	if content and type(content) ~= "string" then
		content = ""
	end

	-- Original Business Logic
	local id = self:Hash("page", math.random(2000000000))

	AngryAssign_Pages[id] = {
		Id = id,
		Updated = time(),
		UpdateId = self:Hash(name, content or ""),
		Name = name,
		Contents = content or "",
		CategoryId = categoryId,
		Index = index
	}

	if categoryId then
	   if AngryAssign_State.tree.groups then
		   if AngryAssign_State.tree.groups[categoryId] == nil then
			   AngryAssign_State.tree.groups[categoryId] = true
		   end
	   end
	end

	self:UpdateTree(id)
	self:SendPage(id, true)

	return true, nil, id
end

--- Renames a page and broadcasts the update.
-- @tparam number id Page id.
-- @tparam string|table nameOrFrame New name text or popup/editbox frame.
-- @treturn boolean ok
-- @treturn string|nil err Error message when rename fails.
function AngryEra:RenamePage(id, nameOrFrame)
	-- Check Existence
	local page = self:Get(id)
	if not page then
		return false, "Page not found."
	end

	-- Check Permissions
	if not self:PermissionCheck() then
		return false, "Permission denied."
	end

	-- Validate and Clean Input
	local name, err = ExtractAndValidateName(nameOrFrame)
	if not name then
		return false, err
	end

	-- Optimization: Skip if name hasn't changed
	if page.Name == name then
		return true
	end

	-- Original Business Logic
	page.Name = name
	page.Updated = time()
	page.UpdateId = self:Hash(page.Name, page.Contents, page.Vars)

	self:SendPage(id, true)
	self:UpdateTree()

	if AngryAssign_State.displayed == id then
		self:UpdateDisplayed()
		self:ShowDisplay()
	end

	return true
end

--- Deletes a page from local storage and selection state.
-- @tparam number id Page id.
function AngryEra:DeletePage(id)
	self:CancelPageTimer(id)

	AngryAssign_Pages[id] = nil
	if self.window and self:SelectedId() == id then
		self:SetSelectedId(nil)
		self:UpdateSelected(true)
	end
	if AngryAssign_State.displayed == id then
		self:ClearDisplayed()
	end
	self:UpdateTree()
end

function AngryEra:TouchPage(id)
	if not self:PermissionCheck() then
		return
	end
	local page = self:Get(id)
	if not page then
		return
	end

	page.Updated = time()
end

--- Creates a category.
-- @tparam string|table nameOrFrame Category name text or popup/editbox frame.
-- @treturn boolean ok
-- @treturn string|nil err Error message on failure.
-- @treturn number|nil id New category id on success.
function AngryEra:CreateCategory(nameOrFrame)
	-- Validate and Clean Input using your new helper
	local name, err = ExtractAndValidateName(nameOrFrame)
	if not name then
		return false, err
	end

	-- Generate ID and Save
	local id = self:Hash("cat", math.random(2000000000))

	AngryAssign_Categories[id] = { Id = id, Name = name }

	if AngryAssign_State.tree.groups then
		AngryAssign_State.tree.groups[ -id ] = true
	end
	self:UpdateTree()

	return true, nil, id
end

--- Renames a category.
-- @tparam number id Category id.
-- @tparam string|table nameOrFrame New name text or popup/editbox frame.
-- @treturn boolean ok
-- @treturn string|nil err Error message when rename fails.
function AngryEra:RenameCategory(id, nameOrFrame)
	local cat = self:GetCat(id)
	if not cat then
		return false, "Category not found."
	end

	-- Use the helper to validate input (Consistency with CreatePage/RenamePage)
	local name, err = ExtractAndValidateName(nameOrFrame)
	if not name then
		return false, err
	end

	if cat.Name == name then
		return true
	end

	cat.Name = name
	self:UpdateTree()

	return true
end

--- Deletes a category but keeps its descendants by moving them upward.
-- @tparam number id Category id.
function AngryEra:DeleteCategory(id)
	local cat = self:GetCat(id)
	if not cat then
		return
	end

	local selectedId = self:SelectedId()

	for _, c in pairs(AngryAssign_Categories) do
		if cat.Id == c.CategoryId then
			c.CategoryId = cat.CategoryId
		end
	end

	for _, p in pairs(AngryAssign_Pages) do
		if cat.Id == p.CategoryId then
			p.CategoryId = cat.CategoryId
		end
	end

	-- Remove the expanded/collapsed state for this category
	if AngryAssign_State.tree.groups then
		AngryAssign_State.tree.groups[-id] = nil
	end

	AngryAssign_Categories[id] = nil

	self:UpdateTree()
	self:SetSelectedId(selectedId)
end

--- Deletes a category and all descendants.
-- @tparam number id Category id.
function AngryEra:DeleteCategoryAndChildren(id)
	local cat = self:GetCat(id)
	if not cat then
		return
	end

	local selectedId = self:SelectedId()

	self:DeleteCategoryChildren(id)

	if AngryAssign_State.tree.groups then
		AngryAssign_State.tree.groups[-id] = nil
	end

	AngryAssign_Categories[id] = nil

	self:UpdateTree()
	self:SetSelectedId(selectedId)
end

--- Assigns a page/category into a category (or toggles back to root).
-- @tparam number entryId Positive for page id, negative for category id.
-- @tparam number parentId Target category id.
function AngryEra:AssignCategory(entryId, parentId)
	local page, cat
	if entryId > 0 then
		page = self:Get(entryId)
	else
		cat = self:GetCat(-entryId)
	end
	local parent = self:GetCat(parentId)
	if not (page or cat) or not parent then
		return
	end

	if page then
		if page.CategoryId == parentId then
			page.CategoryId = nil
		else
			page.CategoryId = parentId
		end
	end

	if cat then
		if cat.CategoryId == parentId then
			cat.CategoryId = nil
		else
			if IsCategoryDescendant(parentId, cat.Id) then
				self:Print("Cannot move into self.")
				return
			end
			cat.CategoryId = parentId
		end
	end

	local selectedId = self:SelectedId()
	self:UpdateTree()
	if selectedId == entryId then
		self:SetSelectedId( selectedId )
	end
end

--- Updates a page's contents, history, hash, and sync state.
-- @tparam number id Page id.
-- @tparam string value New page content.
function AngryEra:UpdateContents(id, value)
	if not self:PermissionCheck() then
		return
	end
	local page = self:Get(id)
	if not page then
		return
	end

	local new_content = value:gsub("^%s+", ""):gsub("%s+$", "")
	local contents_updated = new_content ~= page.Contents

	if contents_updated then
		self:PushHistory(page, page.Contents, "Local")
	end

	page.Contents = new_content
	page.Backup = new_content
	page.Updated = time()
	page.UpdateId = self:Hash(page.Name, page.Contents, page.Vars)

	self:SendPage(id, true)
	self:UpdateSelected(true)
	if AngryAssign_State.displayed == id then
		self:UpdateDisplayed()
		self:ShowDisplay()
		if contents_updated then
			self:DisplayUpdateNotification()
		end
	end
end

function AngryEra:PushHistory(page, content, author)
	if not page or not content or content == "" then
		return
	end
	if not page.History then
		page.History = {}
	end

	-- Avoid duplicate consecutive entries
	if #page.History > 0 and page.History[1].content == content then
		return
	end

	table.insert(page.History, 1, {
		timestamp = time(),
		content = content,
		author = author or "Unknown"
	})

	-- Cap history size (e.g. 10)
	while #page.History > 10 do
		table.remove(page.History)
	end
end


function AngryEra:CreateBackup()
	for _, page in pairs(AngryAssign_Pages) do
		page.Backup = page.Contents
	end
	self:UpdateSelected()
end

--- Clears the currently displayed page selection.
function AngryEra:ClearDisplayed()
	AngryAssign_State.displayed = nil
	self:UpdateDisplayed()
	self:UpdateTree()
end
