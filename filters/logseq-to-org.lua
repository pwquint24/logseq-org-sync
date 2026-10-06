-- logseq-to-org.lua: Pandoc Lua filter to convert Logseq Markdown to Org-roam Org mode.
-- Focuses on non-standard Logseq features: outlining, properties, embeds, block links, etc.

-- Helper: URL decode
local function url_decode(str)
  if not str then return "" end
  return (str:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

-- Helper: Generate UUIDv4
local function generate_uuid()
  local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
  return string.gsub(template, "[xy]", function(c)
    local v = (c == "x") and math.random(0, 0xf) or math.random(8, 0xb)
    return string.format("%x", v)
  end)
end

-- Helper: String trim
local function trim(s)
  if not s then return "" end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

-- Helper: Clean title from filename
local function title_from_path(filepath)
  if not filepath or filepath == "" or filepath == "-" then
    return "Untitled"
  end
  local name = filepath:match("([^/\\]+)%.%w+$") or filepath:match("([^/\\]+)$") or filepath
  name = name:gsub("%.md$", ""):gsub("%.markdown$", "")
  name = url_decode(name)
  name = name:gsub("___", "/")
  return name
end

-- Helper: Check if string is a valid UUID
local function is_uuid(s)
  if not s then return false end
  return s:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$") ~= nil
end

-- Helper: Convert list of tags to Org :tag1:tag2: format
local function format_org_filetags(tags_str)
  if not tags_str or tags_str == "" then return nil end
  local tags = {}
  for tag in tags_str:gmatch("[^,]+") do
    local t = trim(tag):gsub("^#", ""):gsub("%[%[", ""):gsub("%]%]", "")
    t = trim(t):gsub("%s+", "_")
    if t ~= "" then
      table.insert(tags, t)
    end
  end
  if #tags == 0 then return nil end
  return ":" .. table.concat(tags, ":") .. ":"
end

-- Helper: Convert aliases to Org :ROAM_ALIASES: format
local function format_org_roam_aliases(aliases_str)
  if not aliases_str or aliases_str == "" then return nil end
  local aliases = {}
  for alias in aliases_str:gmatch("[^,]+") do
    local a = trim(alias):gsub('^"(.-)"$', "%1")
    if a ~= "" then
      table.insert(aliases, string.format('"%s"', a))
    end
  end
  if #aliases == 0 then return nil end
  return table.concat(aliases, " ")
end

-- Convert inlines to text preserving newlines at SoftBreak/LineBreak
local function inlines_to_text(inlines)
  if not inlines then return "" end
  local t = {}
  for _, inline in ipairs(inlines) do
    if inline.t == "SoftBreak" or inline.t == "LineBreak" then
      table.insert(t, "\n")
    elseif inline.t == "Space" then
      table.insert(t, " ")
    elseif inline.t == "Str" then
      table.insert(t, inline.text)
    elseif inline.t == "Code" then
      table.insert(t, inline.text)
    else
      table.insert(t, pandoc.utils.stringify(inline))
    end
  end
  return table.concat(t)
end

-- Split a list of inlines into lines (array of inlines arrays) on SoftBreak / LineBreak
local function split_inlines_by_line(inlines)
  local lines = {}
  local cur = {}
  for _, inl in ipairs(inlines) do
    if inl.t == "SoftBreak" or inl.t == "LineBreak" then
      table.insert(lines, cur)
      cur = {}
    else
      table.insert(cur, inl)
    end
  end
  if #cur > 0 then
    table.insert(lines, cur)
  end
  return lines
end

-- Check if an inlines list is empty or whitespace only
local function is_empty_inlines(inlines)
  if not inlines or #inlines == 0 then return true end
  local str = inlines_to_text(inlines)
  return trim(str) == ""
end

-- Check if a block is empty
local function is_empty_block(block)
  if not block then return true end
  if block.t == "Plain" or block.t == "Para" then
    return is_empty_inlines(block.content)
  end
  return false
end

-- Parse properties and planning from an inlines list, separating out content lines
local function separate_properties_from_inlines(inlines)
  local lines = split_inlines_by_line(inlines)
  local props = {}
  local planning = {}
  local kept_lines = {}
  
  for _, line in ipairs(lines) do
    local text = inlines_to_text(line)
    local trimmed = trim(text)
    local k, v = trimmed:match("^([%w_%-%.]+)::%s*(.*)$")
    local sched = trimmed:match("^SCHEDULED:%s*(<.->)$")
    local dead = trimmed:match("^DEADLINE:%s*(<.->)$")
    
    if k and v then
      props[k:lower()] = { raw_key = k, val = trim(v) }
    elseif sched then
      planning.scheduled = sched
    elseif dead then
      planning.deadline = dead
    else
      if trimmed ~= "" then
        table.insert(kept_lines, line)
      end
    end
  end
  
  -- Recombine kept lines with SoftBreak
  local kept_inlines = {}
  for idx, l in ipairs(kept_lines) do
    if idx > 1 then
      table.insert(kept_inlines, pandoc.SoftBreak())
    end
    for _, inl in ipairs(l) do
      table.insert(kept_inlines, inl)
    end
  end
  
  return kept_inlines, props, planning
end

-- Extract leading page properties from the start of doc.blocks
local function extract_page_properties(blocks)
  local page_props = {}
  local planning = {}
  local consumed = 0
  
  for _, block in ipairs(blocks) do
    if block.t == "Para" or block.t == "Plain" then
      local kept, props, plan = separate_properties_from_inlines(block.content)
      local found_any = false
      for k, v in pairs(props) do
        found_any = true
        page_props[k] = v
      end
      if plan.scheduled then planning.scheduled = plan.scheduled end
      if plan.deadline then planning.deadline = plan.deadline end
      
      if found_any and #kept == 0 then
        consumed = consumed + 1
      else
        break
      end
    else
      break
    end
  end
  
  for _ = 1, consumed do
    table.remove(blocks, 1)
  end
  
  return page_props, planning
end

-- Build Org-roam file header
local function build_org_roam_header(page_props, filename)
  local title = nil
  local id = nil
  local aliases = nil
  local filetags = nil
  local extra_props = {}
  
  if page_props["title"] then
    title = page_props["title"].val
  end
  if not title or title == "" then
    title = title_from_path(filename)
  end
  
  if page_props["id"] and is_uuid(page_props["id"].val) then
    id = page_props["id"].val
  else
    id = generate_uuid()
  end
  
  local alias_raw = page_props["alias"] or page_props["aliases"]
  if alias_raw then
    aliases = format_org_roam_aliases(alias_raw.val)
  end
  
  local tags_raw = page_props["tags"] or page_props["filetags"]
  if tags_raw then
    filetags = format_org_filetags(tags_raw.val)
  end
  
  for k, v in pairs(page_props) do
    if k ~= "title" and k ~= "id" and k ~= "alias" and k ~= "aliases" and k ~= "tags" and k ~= "filetags" then
      table.insert(extra_props, { key = v.raw_key:upper(), val = v.val })
    end
  end
  table.sort(extra_props, function(a, b) return a.key < b.key end)
  
  local lines = { ":PROPERTIES:", string.format(":ID:       %s", id) }
  if aliases then
    table.insert(lines, string.format(":ROAM_ALIASES: %s", aliases))
  end
  for _, p in ipairs(extra_props) do
    table.insert(lines, string.format(":%s: %s", p.key, p.val))
  end
  table.insert(lines, ":END:")
  table.insert(lines, string.format("#+title: %s", title))
  if filetags then
    table.insert(lines, string.format("#+filetags: %s", filetags))
  end
  table.insert(lines, "")
  
  return table.concat(lines, "\n")
end

-- Extract tags from headline inlines, returning cleaned inlines and list of tag strings
local function extract_headline_tags(inlines)
  local tags = {}
  local new_inlines = {}
  
  for _, inl in ipairs(inlines) do
    if inl.t == "Str" then
      local text = inl.text
      
      -- Temporarily mask priority cookies [#A] etc. so they don't get hit by tag extraction
      local masked = text:gsub("(%[#[ABC]%])", "%%PRIO%%")
      
      -- Multi-word tag: #[[multi word tag]]
      masked = masked:gsub("#%[%[(.-)%]%]", function(t)
        table.insert(tags, (t:gsub("%s+", "_")))
        return ""
      end)
      -- Single tag: #tag
      masked = masked:gsub("#([%w_%-]+)", function(t)
        table.insert(tags, t)
        return ""
      end)
      
      -- Restore masked priority cookies
      local final_text = masked:gsub("%%PRIO%%", function()
        return text:match("(%[#[ABC]%])")
      end)
      
      if final_text ~= "" then
        table.insert(new_inlines, pandoc.Str(final_text))
      end
    else
      table.insert(new_inlines, inl)
    end
  end
  
  -- If tags found, append Org tag string :tag1:tag2: at the end of inlines
  if #tags > 0 then
    local tag_str = " :" .. table.concat(tags, ":") .. ":"
    table.insert(new_inlines, pandoc.RawInline("org", tag_str))
  end
  
  return new_inlines
end

-- Process inline elements: links, tags, highlights, embeds, etc.
local function transform_inlines(inlines)
  local new_inlines = {}
  local i = 1
  
  while i <= #inlines do
    local inline = inlines[i]
    
    if inline.t == "Link" then
      local target = inline.target
      if target then
        local label = inlines_to_text(inline.content)
        local decoded_target = url_decode(target)
        
        local page_ref = decoded_target:match("^%[%[(.-)%]%]$")
        local block_ref = decoded_target:match("^%(%((.-)%)%)$")
        
        if page_ref then
          -- [Page Alias]([[Page Name]]) -> [[Page Name][Page Alias]]
          table.insert(new_inlines, pandoc.RawInline("org", string.format("[[%s][%s]]", page_ref, label)))
        elseif block_ref then
          -- [Label](((uuid))) -> [[id:uuid][Label]]
          table.insert(new_inlines, pandoc.RawInline("org", string.format("[[id:%s][%s]]", block_ref, label)))
        elseif target:match("^assets/") or target:match("^%.%./assets/") or target:match("^draws/") or target:match("^%.%./draws/") then
          table.insert(new_inlines, pandoc.RawInline("org", string.format("[[file:%s][%s]]", target, label)))
        else
          table.insert(new_inlines, inline)
        end
      else
        table.insert(new_inlines, inline)
      end
      
    elseif inline.t == "Image" then
      local target = inline.target
      local is_asset = target and (target:match("^assets/") or target:match("^%.%./assets/") or target:match("^draws/") or target:match("^%.%./draws/"))
      
      -- Logseq image attributes {:height ..., :width ...}
      local next1 = inlines[i + 1]
      local attr_str = ""
      local skip = 0
      
      if next1 and next1.t == "Str" and next1.text:match("^{:") then
        for j = i + 1, math.min(#inlines, i + 8) do
          local s = inlines_to_text({ inlines[j] })
          attr_str = attr_str .. " " .. s
          if s:match("}$") then
            skip = j - i
            break
          end
        end
      end
      
      local h = attr_str:match(":height%s+(%d+)")
      local w = attr_str:match(":width%s+(%d+)")
      
      if is_asset then
        local org_link = string.format("[[file:%s][]]", target)
        if h or w then
          local attrs = ""
          if w then attrs = attrs .. string.format(" :width %s", w) end
          if h then attrs = attrs .. string.format(" :height %s", h) end
          org_link = string.format("\n#+attr_html:%s\n#+attr_org:%s\n%s", attrs, attrs, org_link)
        end
        table.insert(new_inlines, pandoc.RawInline("org", org_link))
      else
        if h or w then
          local attrs = ""
          if w then attrs = attrs .. string.format(" :width %s", w) end
          if h then attrs = attrs .. string.format(" :height %s", h) end
          table.insert(new_inlines, pandoc.RawInline("org", string.format("\n#+attr_html:%s\n#+attr_org:%s\n", attrs, attrs)))
        end
        table.insert(new_inlines, inline)
      end
      
      i = i + skip
      
    elseif inline.t == "Span" and inline.classes:includes("mark") then
      local marked_text = inlines_to_text(inline.content)
      table.insert(new_inlines, pandoc.RawInline("org", "==" .. marked_text .. "=="))
      
    elseif inline.t == "Str" then
      local text = inline.text
      
      -- Task state mapping (only at the start of a block)
      if i == 1 then
        local kw_map = {
          LATER = "TODO",
          NOW = "NEXT",
          DOING = "STARTED",
          WAITING = "WAIT",
          CANCELLED = "CANCELLED"
        }
        
        -- Check if it starts with [#[ABC]] Keyword
        local prio, kw = text:match("^(%[#[ABC]%])%s+([A-Z]+)$")
        if not prio then
           kw = text:match("^([A-Z]+)$")
        end
        
        if kw and kw_map[kw] then
          if prio then
            text = prio .. " " .. kw_map[kw]
          else
            text = kw_map[kw]
          end
        end
      end

      -- Convert ^^highlight^^ to ==highlight==
      if text:match("%^%^(.-)%^%^") then
        text = text:gsub("%^%^(.-)%^%^", "==%1==")
      end
      
      -- Lookahead for {{embed ...}} across multiple Str/Space nodes
      if text:match("{{embed") then
        local buffer = { inline }
        local buffer_text = text
        local found_end = text:match("}}")
        local k = i + 1
        
        while not found_end and k <= #inlines do
          local next_inl = inlines[k]
          if next_inl.t == "Str" or next_inl.t == "Space" then
            table.insert(buffer, next_inl)
            buffer_text = buffer_text .. inlines_to_text({next_inl})
            if buffer_text:match("}}") then
              found_end = true
            end
            k = k + 1
          else
            break
          end
        end
        
        if found_end then
          local inner = buffer_text:match("{{embed%s+(.-)}}")
          if inner then
            local uuid = inner:match("^%(%((.-)%)%)$")
            local page = inner:match("^%[%[(.-)%]%]$")
            if uuid then
              table.insert(new_inlines, pandoc.RawInline("org", string.format("[[id:%s][#embed]]", uuid)))
              i = k
              goto continue
            elseif page then
              table.insert(new_inlines, pandoc.RawInline("org", string.format("[[%s][#embed]]", page)))
              i = k
              goto continue
            end
          end
        end
      end

      -- Lookahead for [[Page Name]] across multiple Str/Space nodes
      if text:match("^%[%[") and not text:match("]]") then
        local buffer = { inline }
        local buffer_text = text
        local found_end = false
        local k = i + 1
        
        while k <= #inlines do
          local next_inl = inlines[k]
          if next_inl.t == "Str" or next_inl.t == "Space" then
            table.insert(buffer, next_inl)
            buffer_text = buffer_text .. inlines_to_text({next_inl})
            if buffer_text:match("]]") then
              found_end = true
              break
            end
            k = k + 1
          else
            break
          end
        end
        
        if found_end then
          local page_name = buffer_text:match("^%[%[(.-)%]%]$")
          if page_name then
            table.insert(new_inlines, pandoc.RawInline("org", string.format("[[%s]]", page_name)))
            i = k
            goto continue
          end
        end
      end

      if text:match("%(%([0-9a-fA-F%-]+%)%)") then
        text = text:gsub("%(%(([0-9a-fA-F%-]+)%)%)", "[[id:%1]]")
        table.insert(new_inlines, pandoc.RawInline("org", text))
        goto continue
      elseif text:match("#%[%[(.-)%]%]") then
        text = text:gsub("#%[%[(.-)%]%]", "[[%1]]")
        table.insert(new_inlines, pandoc.RawInline("org", text))
        goto continue
      elseif text:match("%[:br%]") then
        text = text:gsub("%[:br%]", "\\\\")
        table.insert(new_inlines, pandoc.RawInline("org", text))
        goto continue
      else
        table.insert(new_inlines, pandoc.Str(text))
      end
      
    elseif inline.t == "RawInline" and inline.format == "html" then
      local u_text = inline.text:match("^<u>(.-)</u>$")
      if u_text then
        table.insert(new_inlines, pandoc.RawInline("org", "_" .. u_text .. "_"))
      else
        table.insert(new_inlines, inline)
      end
      
    else
      table.insert(new_inlines, inline)
    end
    
    ::continue::
    i = i + 1
  end
  
  return new_inlines
end

-- Process Org blocks like #+BEGIN_TIP ... #+END_TIP
local function process_special_block(block)
  if block.t == "Para" or block.t == "Plain" then
    local text = inlines_to_text(block.content)
    local begin_type = text:match("^#%+BEGIN_([%w_]+)") or text:match("^#%+begin_([%w_]+)")
    local end_type = text:match("#%+END_([%w_]+)%s*$") or text:match("#%+end_([%w_]+)%s*$")
    
    if begin_type and end_type and begin_type:lower() == end_type:lower() then
      local clean_text = ""
      for line in text:gmatch("[^\r\n]+") do
        clean_text = clean_text .. line .. "\n"
      end
      return pandoc.RawBlock("org", clean_text)
    end
  end
  return nil
end

-- Check if a block is a standalone block-level element to unpack from lists
local function is_standalone_block(block)
  if not block then return false end
  if block.t == "CodeBlock" or block.t == "BlockQuote" or block.t == "Table" or block.t == "RawBlock" then
    return true
  end
  return false
end

-- Lift Headers and extract properties from BulletList items
local function process_bullet_list(bullet_list)
  local result_blocks = {}
  local pending_list_items = {}
  local is_ordered = false
  
  local function flush_pending_items()
    if #pending_list_items > 0 then
      if is_ordered then
        table.insert(result_blocks, pandoc.OrderedList(pending_list_items))
      else
        table.insert(result_blocks, pandoc.BulletList(pending_list_items))
      end
      pending_list_items = {}
      is_ordered = false
    end
  end

  for _, item_blocks in ipairs(bullet_list.content) do
    if #item_blocks > 0 then
      local first_block = item_blocks[1]
      local has_header = false
      local header_block = nil
      
      -- Check if first block is Header or starts with # Heading in text
      if first_block.t == "Header" then
        has_header = true
        header_block = first_block
        header_block.identifier = ""
      elseif (first_block.t == "Para" or first_block.t == "Plain") then
        local str = inlines_to_text(first_block.content)
        local hashes, title_text = str:match("^(#+)%s+(.*)$")
        if hashes then
          has_header = true
          local level = #hashes
          header_block = pandoc.Header(level, pandoc.Inlines({ pandoc.Str(title_text) }))
          header_block.identifier = ""
        end
      end
      
      if has_header then
        flush_pending_items()
        
        local item_props = {}
        local item_planning = {}
        local remaining_blocks = {}
        
        for idx = 2, #item_blocks do
          local b = item_blocks[idx]
          if b.t == "Para" or b.t == "Plain" then
            local kept, props, plan = separate_properties_from_inlines(b.content)
            for k, v in pairs(props) do item_props[k] = v end
            if plan.scheduled then item_planning.scheduled = plan.scheduled end
            if plan.deadline then item_planning.deadline = plan.deadline end
            if #kept > 0 then
              b.content = transform_inlines(kept)
              table.insert(remaining_blocks, b)
            end
          else
            table.insert(remaining_blocks, b)
          end
        end
        
        if item_props["id"] then
          header_block.attributes["ID"] = item_props["id"].val
        end
        if item_props["collapsed"] then
          header_block.attributes["collapsed"] = item_props["collapsed"].val
        end
        for k, v in pairs(item_props) do
          if k ~= "id" and k ~= "collapsed" then
            header_block.attributes[v.raw_key] = v.val
          end
        end
        
        -- Extract tags from header text and format
        header_block.content = extract_headline_tags(header_block.content)
        header_block.content = transform_inlines(header_block.content)
        table.insert(result_blocks, header_block)
        
        if item_planning.scheduled or item_planning.deadline then
          local plan_str = ""
          if item_planning.scheduled then
            plan_str = plan_str .. "SCHEDULED: " .. item_planning.scheduled .. " "
          end
          if item_planning.deadline then
            plan_str = plan_str .. "DEADLINE: " .. item_planning.deadline .. " "
          end
          table.insert(result_blocks, pandoc.RawBlock("org", trim(plan_str)))
        end
        
        for _, rb in ipairs(remaining_blocks) do
          if rb.t == "BulletList" then
            local sub_blocks = process_bullet_list(rb)
            for _, sb in ipairs(sub_blocks) do
              table.insert(result_blocks, sb)
            end
          else
            table.insert(result_blocks, rb)
          end
        end
        
      else
        -- Check if single item is a standalone block element (unpack from list)
        if #item_blocks == 1 then
          local b = item_blocks[1]
          local special = process_special_block(b)
          if special then
            flush_pending_items()
            table.insert(result_blocks, special)
          elseif is_standalone_block(b) then
            flush_pending_items()
            table.insert(result_blocks, b)
          else
            -- Process single regular block
            local cleaned = {}
            if b.t == "Para" or b.t == "Plain" then
              local kept, props, plan = separate_properties_from_inlines(b.content)
              if props["logseq.order-list-type"] and props["logseq.order-list-type"].val == "number" then
                is_ordered = true
              end
              if #kept > 0 then
                local inlines = transform_inlines(kept)
                if props["id"] then
                  table.insert(inlines, 1, pandoc.RawInline("org", string.format("<<%s>> ", props["id"].val)))
                end
                if plan.scheduled or plan.deadline then
                  local p_str = "\n"
                  if plan.scheduled then p_str = p_str .. "  SCHEDULED: " .. plan.scheduled .. " " end
                  if plan.deadline then p_str = p_str .. "  DEADLINE: " .. plan.deadline .. " " end
                  table.insert(inlines, pandoc.RawInline("org", p_str))
                end
                b.content = inlines
                table.insert(cleaned, b)
              end
            else
              table.insert(cleaned, b)
            end
            if #cleaned > 0 then
              table.insert(pending_list_items, cleaned)
            end
          end
        else
          -- Multiple blocks in item
          local cleaned_item_blocks = {}
          for _, b in ipairs(item_blocks) do
            if b.t == "Para" or b.t == "Plain" then
              local kept, props, plan = separate_properties_from_inlines(b.content)
              if props["logseq.order-list-type"] and props["logseq.order-list-type"].val == "number" then
                is_ordered = true
              end
              local special = process_special_block(b)
              if special then
                table.insert(cleaned_item_blocks, special)
              elseif #kept > 0 then
                local inlines = transform_inlines(kept)
                if props["id"] then
                  table.insert(inlines, 1, pandoc.RawInline("org", string.format("<<%s>> ", props["id"].val)))
                end
                if plan.scheduled or plan.deadline then
                  local p_str = "\n"
                  if plan.scheduled then p_str = p_str .. "  SCHEDULED: " .. plan.scheduled .. " " end
                  if plan.deadline then p_str = p_str .. "  DEADLINE: " .. plan.deadline .. " " end
                  table.insert(inlines, pandoc.RawInline("org", p_str))
                end
                b.content = inlines
                table.insert(cleaned_item_blocks, b)
              end
            elseif b.t == "BulletList" then
              local sub_blocks = process_bullet_list(b)
              for _, sb in ipairs(sub_blocks) do
                table.insert(cleaned_item_blocks, sb)
              end
            else
              table.insert(cleaned_item_blocks, b)
            end
          end
          if #cleaned_item_blocks > 0 then
            table.insert(pending_list_items, cleaned_item_blocks)
          end
        end
      end
    end
  end
  
  flush_pending_items()
  return result_blocks
end

-- Top-level Pandoc document transformation
function Pandoc(doc)
  local filename = PANDOC_STATE.input_files[1] or "default"
  -- Seed math.random with a hash of the filename for deterministic UUIDs in tests
  local seed = 0
  for i = 1, #filename do
    seed = (seed * 31 + string.byte(filename, i)) % 2147483647
  end
  math.randomseed(seed)
  
  local page_props, _ = extract_page_properties(doc.blocks)
  local header_str = build_org_roam_header(page_props, filename)
  local header_block = pandoc.RawBlock("org", header_str)
  
  local new_blocks = { header_block }
  
  for _, block in ipairs(doc.blocks) do
    local special = process_special_block(block)
    if special then
      table.insert(new_blocks, special)
    elseif block.t == "BulletList" then
      local lifted = process_bullet_list(block)
      for _, lb in ipairs(lifted) do
        table.insert(new_blocks, lb)
      end
    elseif block.t == "Header" then
      block.identifier = ""
      block.content = extract_headline_tags(block.content)
      block.content = transform_inlines(block.content)
      table.insert(new_blocks, block)
    elseif block.t == "Para" or block.t == "Plain" then
      if not is_empty_block(block) then
        block.content = transform_inlines(block.content)
        table.insert(new_blocks, block)
      end
    elseif block.t == "Figure" or block.t == "BlockQuote" then
      -- Walk nested content to transform inlines
      table.insert(new_blocks, pandoc.walk_block(block, {
        Inlines = transform_inlines
      }))
    else
      table.insert(new_blocks, block)
    end
  end
  
  doc.blocks = new_blocks
  return doc
end
