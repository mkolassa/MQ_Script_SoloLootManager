local SoloLootManager = { _version = '1.0', author = 'Jackalo' }

--- @type Mq
local mq = require('mq')

--- @type ImGui
require('ImGui')

local ImguiHelper = require('mq/ImguiHelper')

-- https://gitlab.com/Knightly1/knightlinc
local Write = require('libraries/Write')
Write.prefix = 'SLM'
Write.loglevel = 'info'

local PackageMan = require('mq/PackageMan')

local lsql = PackageMan.Require('lsqlite3') do
  Write.Debug("lsqlite version: %s", lsql.version())
end

local DBPath = string.format('%s\\%s', mq.configDir, 'SoloLootManager.sqlite3')

-- EQ Texture Animation references
local Animation_Item = mq.FindTextureAnimation('A_DragItem')

local Table_Cache = {
  Rules = {},
  Filtered = {},
  Unhandled = {},
  Inventory = {},
  Corpse = {},
}

local Lookup = {
  Rules = {},
}

local Constant = {
  Icon = {
    Height  = 20,
    Width   = 20,
    Offset  = 500,
  },
}

local GUI_Main = {
  Open  = true,
  Show  = true,

  Flags = bit32.bor(ImGuiWindowFlags.NoResize, ImGuiWindowFlags.AlwaysAutoResize),

  Action = {
    LootCorpse    = false,
    SellItems     = false,
    DonateTribute = false,
  },
}

local GUI_Config = {
  Open = false,
  Show = false,

  --Flags = bit32.bor(0),

  Refresh = {
    Sort = {
      Rules     = false,
      Unhandled = false,
      Inventory = false,
      Corpse    = false,
    },

    Table = {
      Rules     = false,
      Filtered  = false,
      Unhandled = false,
      Inventory = false,
      Corpse    = false,
    },
  },

  Search = '',

  Table = {
    Column_ID = {
      ID        = 1,
      Icon      = 2,
      Name      = 3,
      Value     = 4,
      Tribute   = 5,
      Action    = 6,
      Remove    = 7,
    },

    Flags = bit32.bor(
      ImGuiTableFlags.Resizable,
      ImGuiTableFlags.Sortable,
      ImGuiTableFlags.NoSavedSettings,
      ImGuiTableFlags.RowBg,
      ImGuiTableFlags.BordersV,
      ImGuiTableFlags.BordersOuter,
      ImGuiTableFlags.SizingStretchProp,
      ImGuiTableFlags.ScrollY,
      ImGuiTableFlags.Hideable
    ),

    SortSpecs = {
      Rules     = nil,
      Unhandled = nil,
      Inventory = nil,
      Corpse    = nil,
    },
  },
}



---@class Database
---@field private version integer
---@field private connection any lsqlite3.open() object
local Database = {version = 1} do
  ---@param dbpath string
  ---@return Database object
  function Database:new(dbpath)
    local obj = {}

    setmetatable(obj, self)

    self.__index = self

    self.connection = lsql.open(dbpath)

    self.connection:exec('PRAGMA primary_keys=on')

    self:Initialize()

    self:CheckDatabase()

    return obj
  end

  ---@package
  function Database:CheckDatabase()
    local dbVersion = self:GetConfig('version')

    -- If there's a revision, upgrade here in steps to each successive version and recurse this function
    if dbVersion == '1' then
      Write.Debug("dbVersion is current: v%s", dbVersion)
    elseif dbVersion ~= nil then
      Write.Fatal("unknown database version: %s", dbVersion)
      mq.exit()
    end
  end

  ---@package
  ---Initializes a database with the default tables and values.
  function Database:Initialize()
    self.connection:exec([[
      CREATE TABLE IF NOT EXISTS config(
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );

      INSERT INTO config (key, value) VALUES ("version", "1")
        ON CONFLICT DO NOTHING;

      CREATE TABLE IF NOT EXISTS enum_action(
        enum TEXT PRIMARY KEY
      );

      INSERT INTO enum_action (enum) VALUES ("unhandled")
        ON CONFLICT DO NOTHING;
      INSERT INTO enum_action (enum) VALUES ("ignore")
        ON CONFLICT DO NOTHING;
      INSERT INTO enum_action (enum) VALUES ("keep")
        ON CONFLICT DO NOTHING;
      INSERT INTO enum_action (enum) VALUES ("sell")
        ON CONFLICT DO NOTHING;
      INSERT INTO enum_action (enum) VALUES ("tribute")
        ON CONFLICT DO NOTHING;

      CREATE TABLE IF NOT EXISTS rule(
        id INTEGER PRIMARY KEY,
        icon INTEGER,
        name TEXT NOT NULL,
        itemlink TEXT,
        value INTEGER DEFAULT 0,
        tribute INTEGER DEFAULT 0,
        enum_action TEXT DEFAULT "unhandled",
        CONSTRAINT fk_enum_action
          FOREIGN KEY (enum_action)
          REFERENCES enum_action (enum)
      );
    ]])
  end

  ---@package
  ---Called before Initialize() to wipe the database first.
  function Database:Reinitialize()
    self.connection:exec([[
      DROP TABLE IF EXISTS config;
      DROP TABLE IF EXISTS rule;
      DROP TABLE IF EXISTS enum_action;
    ]])

    self:Initialize()
  end

  ---@package
  ---@param key string
  ---@param value string
  function Database:AddConfig(key, value)
    local stm = self.connection:prepare([[INSERT INTO config (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value]])

    stm:bind_values(key, value)
    stm:step()
    stm:finalize()
  end

  ---@package
  ---@param key string
  function Database:RemoveConfig(key)
    local stm = self.connection:prepare([[DELETE FROM config WHERE key = ?]])

    stm:bind_values(key)
    stm:step()
    stm:finalize()
  end

  ---@package
  ---@param key string
  ---@return string
  function Database:GetConfig(key)
    local stm = self.connection:prepare([[SELECT value FROM config WHERE key = ?]])

    stm:bind_values(key)

    for row in stm:nrows() do
      stm:finalize()

      return row.value
    end
  end

  ---@private
  function RuleToEntry(rule)
    local entry = {
      ID = rule.id,
      Icon = rule.icon,
      Name = rule.name,
      ItemLink = rule.itemlink,
      Value = rule.value or 0,
      Tribute = rule.tribute or 0,
      Enum_Action = rule.enum_action,
    }

    return entry
  end

  ---@private
  local function EntryToRule(entry)
    local rule = {
      icon = entry.Icon,
      name = entry.Name,
      itemlink = entry.ItemLink,
      value = entry.Value or 0,
      tribute = entry.Tribute or 0,
      enum_action = entry.Enum_Action,
    }

    return rule
  end

  ---@package
  ---@param id integer
  ---@param entry table
  function Database:AddRule(id, entry)
    local keys, values, conflict
    local binds = {}

    table.insert(binds, id)

    for k,v in pairs(EntryToRule(entry)) do
      if #binds > 1 then
        keys = keys .. ', ' .. k
        values = values .. ', ?'
        conflict = conflict .. string.format(', %s = excluded.%s', k, k)
      else
        keys = k
        values = '?'
        conflict = string.format('%s = excluded.%s', k, k)
      end

      table.insert(binds, v)
    end

    local query = string.format([[INSERT INTO rule (id, %s) VALUES (?, %s) ON CONFLICT (id) DO UPDATE SET %s]], keys, values, conflict)

    local stm = self.connection:prepare(query)

    stm:bind_values(unpack(binds))
    stm:step()
    stm:finalize()
  end

  ---@package
  ---@param id integer
  function Database:RemoveRule(id)
    local stm = self.connection:prepare([[DELETE FROM rule WHERE id = ?]])

    stm:bind_values(id)
    stm:step()
    stm:finalize()
  end

  ---@package
  ---@param id string
  ---@return table
  function Database:GetRule(id)
    local stm = self.connection:prepare([[SELECT * FROM rule WHERE id = ?]])

    stm:bind_values(id)

    for row in stm:nrows() do
      stm:finalize()

      return RuleToEntry(row)
    end
  end

  ---@package
  ---@return table
  function Database:GetAllRules()
    local stm = self.connection:prepare([[SELECT * FROM rule]])

    local newTable = {}

    for row in stm:nrows() do
      table.insert(newTable, RuleToEntry(row))
    end

    return newTable
  end
end

local DB = Database:new(DBPath)

local function ReinitializeDB()
  local title = "SLM > Reinitialize Warning"
  local text = "Are you really sure you want to wipe the database?"

  if ImguiHelper.Popup.Modal(title, text, { "Yes", "Cancel" }) == 1 then
    DB:Reinitialize()
  end
end



local function AddRule(entry)
  Write.Debug('AddRule [%s] %s', entry.Enum_Action, entry.ItemLink)

  DB:AddRule(entry.ID, entry)

  GUI_Config.Refresh.Table.Rules = true
  GUI_Config.Refresh.Table.Filtered = true
  GUI_Config.Refresh.Table.Unhandled = true
end

local function RemoveRule(entry)
  Write.Debug('RemoveRule [%s] %s', entry.Enum_Action, entry.ItemLink)

  DB:RemoveRule(entry.ID)

  GUI_Config.Refresh.Table.Rules = true
  GUI_Config.Refresh.Table.Filtered = true
  GUI_Config.Refresh.Table.Unhandled = true
end

local function CheckRule(entry)
  if Lookup.Rules[entry.ID] then
    return true
  else
    return false
  end
end

local function Compare(entryValue, wantedValue)
  if entryValue == wantedValue then
    return true
  else
    return false
  end
end

local function AreBagsOpen()
  local total = {
    bags = 0,
    open = 0,
  }

  for i = 23, 32 do
    local slot = mq.TLO.Me.Inventory(i)

    if slot and slot.Container() and slot.Container() > 0 then
      total.bags = total.bags + 1

      if slot.Open() then
        total.open = total.open + 1
      end
    end
  end

  if total.bags == total.open then
    return true
  else
    return false
  end
end

local function AreBagsClosed()
  return not AreBagsOpen()
end

local function ValueToCoinString(value)
  local newString = ''

  if string.len(value) >= 1 then
    local coinValue = string.sub(value, -1, -1)

    if coinValue ~= '0' then
      newString = string.format('%sc ', coinValue)
    end
  end

  if string.len(value) >= 2 then
    local coinValue = string.sub(value, -2, -2)

    if coinValue ~= '0' then
      newString = string.format('%ss %s', coinValue, newString)
    end
  end

  if string.len(value) >= 3 then
    local coinValue = string.sub(value, -3, -3)

    if coinValue ~= '0' then
      newString = string.format('%sg %s', coinValue, newString)
    end
  end

  if string.len(value) >= 4 then
    local coinValue = string.sub(value, 1, -4)

    if coinValue ~= '0' then
      newString = string.format('%sp %s', coinValue, newString)
    end
  end

  if newString == '' then
    newString = '0'
  end

  return string.gsub(newString, '^%s*(.-)%s*$', '%1')
end

local function ItemToLocation(item, slotPrefix)
  local slotNumber

  if slotPrefix ~= nil then
    slotNumber = item.ItemSlot() + 1
  else
    slotPrefix = 'pack'
    slotNumber = item.ItemSlot() - 22
  end

  if item.ItemSlot2() == -1 then
    return string.format('%s%s', slotPrefix, slotNumber)
  else
    return string.format('in %s%s %s', slotPrefix, slotNumber, item.ItemSlot2() + 1)
  end
end

local function ItemToEntry(item)
  local entry = {
    ID = item.ID(),
    Icon = item.Icon(),
    Name = item.Name(),
    ItemLink = item.ItemLink('CLICKABLE')(),
    Value = item.Value(),
    Tribute = item.Tribute(),
    Quantity = (item.Stack() > 1 and item.Stack() or 1),
    Slot = ItemToLocation(item),

    Enum_Action = 'unhandled',
  }

  return entry
end

local function InsertTableItem(dataTable, item, opts)
  local entry = ItemToEntry(item)

  if opts then
    for k,v in pairs(opts) do
      if k == 'inCorpseSlot' then
        entry['Slot'] = ItemToLocation(item, 'loot')
      else
        entry[k] = v
      end
    end
  end

  table.insert(dataTable, entry)
end

local function InsertTableContainer(dataTable, slot, opts)
  for i = 1, slot.Container() do
    local item = slot.Item(i)

    if item() then
      InsertTableItem(dataTable, item, opts)
    end
  end
end

local function RefreshRules()
  Table_Cache.Rules = DB:GetAllRules()

  local newTable = {}

  for k,v in ipairs(Table_Cache.Rules) do
    table.insert(newTable, v.ID, k)
  end

  Lookup.Rules = newTable

  GUI_Config.Refresh.Table.Filtered = true
  GUI_Config.Refresh.Table.Unhandled = true

  GUI_Config.Refresh.Table.Rules = false
end

local function RefreshFiltered()
  local splitSearch = {}

  for part in string.gmatch(GUI_Config.Search, '[^%s]+') do
    table.insert(splitSearch, part)
  end

  local newTable = {}

  for k,v in ipairs(Table_Cache.Rules) do
    local found = 0

    for _,search in ipairs(splitSearch) do
      if string.find(string.lower(v.Name), string.lower(search)) then
        found = found + 1
      end
    end

    if #splitSearch == found then
      table.insert(newTable, v)
    end
  end

  Table_Cache.Filtered = newTable

  GUI_Config.Refresh.Sort.Rules = true

  GUI_Config.Refresh.Table.Filtered = false
end

local function RefreshUnhandled()
  local newTable = {}

  for k,v in ipairs(Table_Cache.Rules) do
    if v.Enum_Action == 'unhandled' then
      table.insert(newTable, v)
    end
  end

  Table_Cache.Unhandled = newTable

  GUI_Config.Refresh.Sort.Unhandled = true

  GUI_Config.Refresh.Table.Unhandled = false
end

local function RefreshInventory()
  local newTable = {}

  for i = 23, 32 do
    local slot = mq.TLO.Me.Inventory(i)

    if slot.Container() then
      InsertTableContainer(newTable, slot)
    elseif slot.ID() ~= nil then
      InsertTableItem(newTable, slot)
    end
  end

  Table_Cache.Inventory = newTable

  for k,v in ipairs(Table_Cache.Inventory) do
    if not CheckRule(v) then
      AddRule(v)
    end
  end

  GUI_Config.Refresh.Sort.Inventory = true

  GUI_Config.Refresh.Table.Inventory = false
end

local function RefreshCorpse()
  local newTable = {}

  for i = 1, 31 do
    local slot = mq.TLO.Corpse.Item(i)

    if slot.ID() ~= nil then
      InsertTableItem(newTable, slot, {inCorpseSlot = true})
    end
  end

  Table_Cache.Corpse = newTable

  for k,v in ipairs(Table_Cache.Corpse) do
    if not CheckRule(v) then
      AddRule(v)
    end
  end

  GUI_Config.Refresh.Sort.Corpse = true

  GUI_Config.Refresh.Table.Corpse = false
end



local function LootCorpseItem(item)
  if mq.TLO.Corpse.Open() then
    mq.cmdf('/nomodkey /shiftkey /itemnotify %s leftmouseup', ItemToLocation(item, 'loot'))

    mq.delay(1000, function() return mq.TLO.Cursor() ~= nil end)
    mq.delay(1)

    mq.cmd('/autoinventory')

    mq.delay(1000, function() return mq.TLO.Cursor() == nil end)
    mq.delay(1)
  end
end

local function LootCorpse()
  if mq.TLO.Corpse.Open() then
    local total = {
      items     = 0,
      value     = 0,
      tribute   = 0,
      unhandled = 0,
    }

    if mq.TLO.Corpse.Items() > 0 then
      for i = 1, mq.TLO.Corpse.Items() do
        local item = mq.TLO.Corpse.Item(i)

        if item.ID() ~= nil then
          local rule = DB:GetRule(tostring(item.ID()))

          local itemStack = item.Stack()
          local itemValue = (item.Value() or 0) * itemStack
          local itemTribute = (item.Tribute() or 0) * itemStack

          if rule.Enum_Action == 'unhandled' then
            total.unhandled = total.unhandled + itemStack

            Write.Warn("Unhandled item: %s", rule.ItemLink)
          elseif rule.Enum_Action == 'ignore' then
            Write.Info("Ignored item: %s", rule.ItemLink)
          elseif rule.Enum_Action == 'keep' or rule.Enum_Action == 'sell' or rule.Enum_Action == 'tribute' then
            if item.Lore() then
              if mq.TLO.FindItem(rule.ID)() or mq.TLO.FindItemBank(rule.ID)() then
                Write.Warn("Skipped duplicate lore item: %s", rule.ItemLink)
              else
                LootCorpseItem(item)

                total.items   = total.items + itemStack
                total.value   = total.value + itemValue
                total.tribute = total.tribute + itemTribute

                Write.Info("Looted lore item: [\ay%s\ax value] [\at%s\ax tribute] %s x %s", ValueToCoinString(itemValue), itemTribute, itemStack, rule.ItemLink)
              end
            else
              LootCorpseItem(item)

              total.items   = total.items + itemStack
              total.value   = total.value + itemValue
              total.tribute = total.tribute + itemTribute

              Write.Info("Looted item: [\ay%s\ax value] [\at%s\ax tribute] %s x %s", ValueToCoinString(itemValue), itemTribute, itemStack, rule.ItemLink)
            end
          end
        end
      end
    end

    if total.items > 0 then
      Write.Info("Total looted: [\ay%s\ax value] [\at%s\ax tribute] [\au%s\ax items]", ValueToCoinString(total.value), total.tribute, total.items)
    else
      Write.Info("No items looted!")
    end

    if total.unhandled > 0 then
      Write.Warn("Unhandled items in corpse, not closing: [\ar%s\ax items]", total.unhandled)
    else
      mq.cmd('/notify LootWnd LW_DoneButton leftmouseup')
    end
  end

  GUI_Main.Action.LootCorpse = false
end



local function SellItem(item)
  if mq.TLO.Window('MerchantWnd').Open() then
    local rule = DB:GetRule(tostring(item.ID()))

    local itemStack = item.Stack()
    local itemValue = (item.Value() or 0) * itemStack

    Write.Debug("Item in inventory: [%s] %s x %s", rule.Enum_Action, item.Stack(), rule.ItemLink)

    if rule.Enum_Action == 'unhandled' then
      Write.Warn("Unhandled item: %s", rule.ItemLink)

      return nil, nil, true
    elseif rule.Enum_Action == 'sell' then
      mq.cmdf('/nomodkey /shiftkey /itemnotify %s leftmouseup', ItemToLocation(item))

      mq.delay(1000, function() return mq.TLO.Window('MerchantWnd/MW_SelectedItemLabel').Text() == item.Name() end)
      mq.delay(1)

      mq.cmd('/nomodkey /shiftkey /notify MerchantWnd MW_Sell_Button leftmouseup')

      mq.delay(1000, function() return mq.TLO.Window('MerchantWnd/MW_SelectedItemLabel').Text() == '' end)
      mq.delay(1)

      Write.Info("Sold item: [\ay%s\ax value] %s x %s", ValueToCoinString(itemValue), itemStack, rule.ItemLink)

      return itemValue, itemStack
    end
  end
end

local function SellItems()
  if mq.TLO.Window('MerchantWnd').Open() then
    local total = {
      items     = 0,
      value     = 0,
      unhandled = 0,
    }

    for i = 23, 32 do
      local slot = mq.TLO.Me.Inventory(i)

      if slot.Container() then
        for j = 1, slot.Container() do
          local item = slot.Item(j)

          if item() then
            local sale, stack, unhandled = SellItem(item)

            if sale then
              total.items = total.items + stack
              total.value = total.value + sale
            elseif unhandled then
              total.unhandled = total.unhandled + 1
            end
          end
        end
      elseif slot.ID() ~= nil then
        local sale, stack, unhandled = SellItem(slot)

        if sale then
          total.items = total.items + stack
          total.value = total.value + sale
        elseif unhandled then
          total.unhandled = total.unhandled + 1
        end
      end
    end

    if total.items > 0 then
      Write.Info("Total sold: [\ay%s\ax value] [\au%s\ax items]", ValueToCoinString(total.value), total.items)
    else
      Write.Info("No items sold!")
    end

    if total.unhandled > 0 then
      Write.Warn("Unhandled items in inventory, not closing: [\ar%s\ax items]", total.unhandled)
    else
      mq.cmd('/nomodkey /shiftkey /notify MerchantWnd MW_Done_Button leftmouseup')
    end
  end

  GUI_Main.Action.SellItems = false
end



local function DonateTributeItem(item)
  if mq.TLO.Window('TributeMasterWnd').Open() then
    local rule = DB:GetRule(tostring(item.ID()))

    local itemStack   = item.Stack()
    local itemTribute = (item.Tribute() or 0) * itemStack

    Write.Debug("Item in inventory: [%s] %s x %s", rule.Enum_Action, item.Stack(), rule.ItemLink)

    if rule.Enum_Action == 'unhandled' then
      Write.Warn("Unhandled item: %s", rule.ItemLink)

      return nil, nil, true
    elseif rule.Enum_Action == 'tribute' then
      -- This delay is necessary because there is seemingly a delay between donating and selecting the next item.
      mq.delay(1000)

      mq.cmdf('/nomodkey /shiftkey /itemnotify %s leftmouseup', ItemToLocation(item))

      mq.delay(1000, function() return tonumber(mq.TLO.Window('TMW_DonateWnd/TMW_ValueLabel').Text()) == item.Tribute() end)
      mq.delay(1)

      mq.delay(1000, function() return mq.TLO.Window('TMW_DonateWnd/TMW_DonateButton').Enabled() end)
      mq.delay(1)

      mq.cmd('/nomodkey /shiftkey /notify TMW_DonateWnd TMW_DonateButton leftmouseup')

      mq.delay(1000, function() return not mq.TLO.Window('TMW_DonateWnd/TMW_DonateButton').Enabled() end)
      mq.delay(1)

      Write.Info("Donated item: [\at%s\ax tribute] %s x %s", itemTribute, itemStack, rule.ItemLink)

      return itemTribute, itemStack
    end
  end
end

local function DonateTribute()
  if mq.TLO.Window('TributeMasterWnd').Open() then
    local total = {
      items     = 0,
      tribute   = 0,
      unhandled = 0,
    }

    mq.cmd('/keypress OPEN_INV_BAGS')

    mq.delay(1000, AreBagsOpen)
    mq.delay(1)

    for i = 23, 32 do
      local slot = mq.TLO.Me.Inventory(i)

      if slot.Container() then
        for j = 1, slot.Container() do
          local item = slot.Item(j)

          if item() then
            local tribute, stack, unhandled = DonateTributeItem(item)

            if tribute then
              total.items   = total.items + stack
              total.tribute = total.tribute + tribute
            elseif unhandled then
              total.unhandled = total.unhandled + 1
            end
          end
        end
      elseif slot.ID() ~= nil then
        local tribute, stack, unhandled = DonateTributeItem(slot)

        if tribute then
          total.items   = total.items + stack
          total.tribute = total.tribute + tribute
        elseif unhandled then
          total.unhandled = total.unhandled + 1
        end
      end
    end

    if total.items > 0 then
      Write.Info("Total donated: [\at%s\ax tribute] [\au%s\ax items]", total.tribute, total.items)
    else
      Write.Info("No items donated!")
    end

    if total.unhandled > 0 then
      Write.Warn("Unhandled items in inventory, not closing: [\ar%s\ax items]", total.unhandled)
    else
      mq.TLO.Window('TributeMasterWnd').DoClose()
    end

    mq.cmd('/keypress CLOSE_INV_BAGS')

    mq.delay(1000, AreBagsClosed)
    mq.delay(1)
  end

  GUI_Main.Action.DonateTribute = false
end



local function TableSortSpecs(a, b)
  for i = 1, GUI_Config.Table.SortSpecs.SpecsCount, 1 do
    local spec = GUI_Config.Table.SortSpecs:Specs(i)

    local delta = 0

    if spec.ColumnUserID == GUI_Config.Table.Column_ID.Name then
      if a.Name < b.Name then
        delta = -1
      elseif a.Name > b.Name then
        delta = 1
      end
    elseif spec.ColumnUserID == GUI_Config.Table.Column_ID.Value then
      if a.Value < b.Value then
        delta = -1
      elseif a.Value > b.Value then
        delta = 1
      end
    elseif spec.ColumnUserID == GUI_Config.Table.Column_ID.Tribute then
      if a.Tribute < b.Tribute then
        delta = -1
      elseif a.Tribute > b.Tribute then
        delta = 1
      end
    elseif spec.ColumnUserID == GUI_Config.Table.Column_ID.Action then
      if a.Enum_Action < b.Enum_Action then
        delta = -1
      elseif a.Enum_Action > b.Enum_Action then
        delta = 1
      end
    end

    if delta ~= 0 then
      if spec.SortDirection == ImGuiSortDirection.Ascending then
        return delta < 0
      else
        return delta > 0
      end
    end
  end

  return a.Name < b.Name
end

local function DrawRuleRow(entry)
  ImGui.TableNextColumn()
  Animation_Item:SetTextureCell(entry.Icon - Constant.Icon.Offset)
  ImGui.DrawTextureAnimation(Animation_Item, Constant.Icon.Width, Constant.Icon.Height)

  if entry.ItemLink ~= nil then
    if ImGui.IsItemHovered() and ImGui.IsMouseReleased(ImGuiMouseButton.Right) then
      mq.cmdf('/executelink %s', entry.ItemLink)
    end
  end

  ImGui.TableNextColumn()
  ImGui.Text('%s', entry.Name)

  if entry.ItemLink ~= nil then
    if ImGui.IsItemHovered() and ImGui.IsMouseReleased(ImGuiMouseButton.Right) then
      mq.cmdf('/executelink %s', entry.ItemLink)
    end
  end

  ImGui.TableNextColumn()
  ImGui.Text('%s', ValueToCoinString(entry.Value))

  ImGui.TableNextColumn()
  ImGui.Text('%s', entry.Tribute)

  ImGui.TableNextColumn()
  if ImGui.RadioButton("Ignore", Compare(entry.Enum_Action, 'ignore')) then
    entry.Enum_Action = 'ignore'

    AddRule(entry)
  end
  ImGui.SameLine()
  if ImGui.RadioButton("Keep", Compare(entry.Enum_Action, 'keep')) then
    entry.Enum_Action = 'keep'

    AddRule(entry)
  end
  ImGui.SameLine()
  if ImGui.RadioButton("Sell", Compare(entry.Enum_Action, 'sell')) then
    entry.Enum_Action = 'sell'

    AddRule(entry)
  end
  ImGui.SameLine()
  if ImGui.RadioButton("Tribute", Compare(entry.Enum_Action, 'tribute')) then
    entry.Enum_Action = 'tribute'

    AddRule(entry)
  end

  ImGui.TableNextColumn()
  if ImGui.SmallButton("Remove") then RemoveRule(entry) end
end



local function DrawMainGUI()
  if GUI_Main.Open then
    GUI_Main.Open = ImGui.Begin("Solo Loot Manager", GUI_Main.Open, GUI_Main.Flags)

    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 2, 2)

    if #Table_Cache.Unhandled > 0 then
      ImGui.PushStyleColor(ImGuiCol.Button, ImVec4(1, 0.3, 0.3, 1))
      ImGui.PushStyleColor(ImGuiCol.ButtonHovered, ImVec4(1, 0.4, 0.4, 1))
      ImGui.PushStyleColor(ImGuiCol.ButtonActive, ImVec4(1, 0.5, 0.5, 1))
    end
    if ImGui.SmallButton("Config") then GUI_Config.Open = not GUI_Config.Open end
    if #Table_Cache.Unhandled > 0 then
      ImGui.PopStyleColor(3)
    end
    ImGui.SameLine()
    if ImGui.SmallButton("Loot Corpse") then GUI_Main.Action.LootCorpse = true end
    ImGui.SameLine()
    if ImGui.SmallButton("Sell Items") then GUI_Main.Action.SellItems = true end
    ImGui.SameLine()
    if ImGui.SmallButton("Donate Tribute") then GUI_Main.Action.DonateTribute = true end

    ImGui.PopStyleVar()

    ImGui.End()
  end
end

local function DrawConfigGUI()
  if GUI_Config.Open then
    GUI_Config.Open, GUI_Config.Show = ImGui.Begin("SLM > Config", GUI_Config.Open)

    if not GUI_Config.Show then
      ImGui.End()
      return GUI_Config.Open
    end

    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 2, 2)

    if ImGui.BeginTabBar('##TabBar') then

      if ImGui.BeginTabItem("All Rules") then
        ImGui.PushItemWidth(-95)
        local searchText, selected = ImGui.InputText("Search##RulesSearch", GUI_Config.Search)
        ImGui.PopItemWidth()

        if selected and GUI_Config.Search ~= searchText then
          GUI_Config.Search = searchText
          GUI_Config.Refresh.Sort.Rules = true
          GUI_Config.Refresh.Table.Filtered = true
        end

        ImGui.SameLine()
        if ImGui.Button("Clear##ClearRulesSearch") then
          GUI_Config.Search = ''

          GUI_Config.Refresh.Sort.Rules = true
          GUI_Config.Refresh.Table.Filtered = true
        end

        ImGui.Separator()

        if ImGui.BeginTable('##RulesTable', 6, GUI_Config.Table.Flags) then
          ImGui.TableSetupScrollFreeze(0, 1)

          ImGui.TableSetupColumn("##icon", ImGuiTableColumnFlags.NoSort, 1, GUI_Config.Table.Column_ID.Icon)
          ImGui.TableSetupColumn("Name", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Config.Table.Column_ID.Name)
          ImGui.TableSetupColumn("Value", ImGuiTableColumnFlags.DefaultSort, 2, GUI_Config.Table.Column_ID.Value)
          ImGui.TableSetupColumn("Tribute", ImGuiTableColumnFlags.DefaultSort, 2, GUI_Config.Table.Column_ID.Tribute)
          ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Config.Table.Column_ID.Action)
          ImGui.TableSetupColumn("Remove", ImGuiTableColumnFlags.DefaultSort, 2, GUI_Config.Table.Column_ID.Remove)

          ImGui.TableHeadersRow()

          local sortSpecs = ImGui.TableGetSortSpecs()
          if sortSpecs and (sortSpecs.SpecsDirty or GUI_Config.Refresh.Sort.Rules) then
            if #Table_Cache.Filtered > 1 then
              GUI_Config.Table.SortSpecs = sortSpecs

              table.sort(Table_Cache.Filtered, TableSortSpecs)

              GUI_Config.Table.SortSpecs = nil
            end

            sortSpecs.SpecsDirty = false
            GUI_Config.Refresh.Sort.Rules = false
          end

          for _,entry in ipairs(Table_Cache.Filtered) do
            ImGui.PushID(entry.ID)

            ImGui.TableNextRow()

            DrawRuleRow(entry)

            ImGui.PopID()
          end

          ImGui.EndTable()
        end

        ImGui.EndTabItem()
      end

      if #Table_Cache.Unhandled > 0 then
        ImGui.PushStyleColor(ImGuiCol.Tab, ImVec4(1, 0.3, 0.3, 1))
        ImGui.PushStyleColor(ImGuiCol.TabHovered, ImVec4(1, 0.4, 0.4, 1))
        ImGui.PushStyleColor(ImGuiCol.TabActive, ImVec4(1, 0.5, 0.5, 1))
      end
      if ImGui.BeginTabItem("Unhandled Rules") then
        if ImGui.BeginTable('##UnhandledRulesTable', 6, GUI_Config.Table.Flags) then
          ImGui.TableSetupScrollFreeze(0, 1)

          ImGui.TableSetupColumn("##icon", ImGuiTableColumnFlags.NoSort, 1, GUI_Config.Table.Column_ID.Icon)
          ImGui.TableSetupColumn("Name", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Config.Table.Column_ID.Name)
          ImGui.TableSetupColumn("Value", ImGuiTableColumnFlags.DefaultSort, 2, GUI_Config.Table.Column_ID.Value)
          ImGui.TableSetupColumn("Tribute", ImGuiTableColumnFlags.DefaultSort, 2, GUI_Config.Table.Column_ID.Tribute)
          ImGui.TableSetupColumn("Action", ImGuiTableColumnFlags.DefaultSort, 8, GUI_Config.Table.Column_ID.Action)
          ImGui.TableSetupColumn("Remove", ImGuiTableColumnFlags.DefaultSort, 2, GUI_Config.Table.Column_ID.Remove)

          ImGui.TableHeadersRow()

          local sortSpecs = ImGui.TableGetSortSpecs()
          if sortSpecs and (sortSpecs.SpecsDirty or GUI_Config.Refresh.Sort.Unhandled) then
            if #Table_Cache.Unhandled > 1 then
              GUI_Config.Table.SortSpecs = sortSpecs

              table.sort(Table_Cache.Unhandled, TableSortSpecs)

              GUI_Config.Table.SortSpecs = nil
            end

            sortSpecs.SpecsDirty = false
            GUI_Config.Refresh.Sort.Unhandled = false
          end

          for _,entry in ipairs(Table_Cache.Unhandled) do
            ImGui.PushID(entry.ID)

            ImGui.TableNextRow()

            DrawRuleRow(entry)

            ImGui.PopID()
          end

          ImGui.EndTable()
        end

        ImGui.EndTabItem()
      end
      if #Table_Cache.Unhandled > 0 then
        ImGui.PopStyleColor(3)
      end

      ImGui.EndTabBar()
    end

    ImGui.PopStyleVar()

    ImGui.End()
  end
end

local function DrawGUI()
  DrawMainGUI()
  DrawConfigGUI()
end

-- Kickstart the data
GUI_Config.Refresh.Table.Rules = true
GUI_Config.Refresh.Table.Filtered = true
GUI_Config.Refresh.Table.Unhandled = true

mq.imgui.init('DrawMainGUI', DrawGUI)

mq.bind("/slmconfig", function() GUI_Config.Open = not GUI_Config.Open end)
mq.bind("/slmlootcorpse", LootCorpse)
mq.bind("/slmsellitems", SellItems)
mq.bind("/slmdonatetribute", DonateTribute)
mq.bind("/slmreinitialize", ReinitializeDB)
mq.bind("/slmquit", function() GUI_Main.Open = not GUI_Main.Open end)

while GUI_Main.Open do
  mq.delay(50)

  if GUI_Config.Refresh.Table.Rules then RefreshRules() end
  if GUI_Config.Refresh.Table.Filtered then RefreshFiltered() end
  if GUI_Config.Refresh.Table.Unhandled then RefreshUnhandled() end

  RefreshInventory()
  RefreshCorpse()

  if GUI_Main.Action.LootCorpse then LootCorpse() end
  if GUI_Main.Action.SellItems then SellItems() end
  if GUI_Main.Action.DonateTribute then DonateTribute() end
end