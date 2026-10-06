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

-- Build Org-mode property drawer for a block/list item
local function build_block_drawer(props)
  local lines = { ":PROPERTIES:" }
  local count = 0
  if props["id"] then
    table.insert(lines, string.format(":id: %s", props["id"].val))
    count = count + 1
  end
  if props["heading"] then
    table.insert(lines, string.format(":heading: %s", props["heading"].val))
    count = count + 1
  end
  if props["collapsed"] then
    table.insert(lines, string.format(":collapsed: %s", props["collapsed"].val))
    count = count + 1
  end
  local other_props = {}
  for k, v in pairs(props) do
    if k ~= "id" and k ~= "heading" and k ~= "collapsed" and k ~= "logseq.order-list-type" then
      table.insert(other_props, { key = v.raw_key:lower(), val = v.val })
    end
  end
  table.sort(other_props, function(a, b) return a.key < b.key end)
  for _, p in ipairs(other_props) do
    table.insert(lines, string.format(":%s: %s", p.key, p.val))
    count = count + 1
  end
  table.insert(lines, ":END:")
  if count > 0 then
    return table.concat(lines, "\n")
  end
  return nil
end

-- Extract task state and priority from inlines
local function extract_task_and_priority(inlines)
  local task_state = nil
  local priority = nil
  local kw_map = {
    LATER = "TODO",
    NOW = "NEXT",
    DOING = "STARTED",
    WAITING = "WAIT",
    CANCELLED = "CANCELLED",
    TODO = "TODO",
    DONE = "DONE"
  }
  local i = 1
  while i <= #inlines and inlines[i].t == "Space" do i = i + 1 end
  if i <= #inlines and inlines[i].t == "Str" then
    local s = inlines[i].text
    local p = s:match("^(%[#[ABC]%])$")
    if p then
      priority = p
      i = i + 1
      while i <= #inlines and inlines[i].t == "Space" do i = i + 1 end
      if i <= #inlines and inlines[i].t == "Str" and kw_map[inlines[i].text] then
        task_state = kw_map[inlines[i].text]
        i = i + 1
      end
    elseif kw_map[s] then
      task_state = kw_map[s]
      i = i + 1
      while i <= #inlines and inlines[i].t == "Space" do i = i + 1 end
      if i <= #inlines and inlines[i].t == "Str" and inlines[i].text:match("^(%[#[ABC]%])$") then
        priority = inlines[i].text
        i = i + 1
      end
    end
  end
  while i <= #inlines and inlines[i].t == "Space" do i = i + 1 end
  local remaining = {}
  for j = i, #inlines do table.insert(remaining, inlines[j]) end
  return task_state, priority, remaining
end

-- Strip leading markdown hashes from inlines (# Heading -> Heading)
local function strip_leading_hashes(inlines)
  local new_inlines = {}
  local stripped = false
  for _, inl in ipairs(inlines) do
    if not stripped and inl.t == "Str" then
      local s = inl.text:gsub("^#+%s*", "")
      if s ~= "" then table.insert(new_inlines, pandoc.Str(s)) end
      stripped = true
    elseif not stripped and inl.t == "Space" then
      -- skip space directly after hash
    else
      table.insert(new_inlines, inl)
    end
  end
  return new_inlines
end

-- Convert inlines to Org headline text using Pandoc Org writer
local function inlines_to_org_text(inlines)
  if not inlines or #inlines == 0 then return "" end
  local doc = pandoc.Pandoc({ pandoc.Plain(inlines) })
  local org_text = pandoc.write(doc, "org")
  return trim(org_text)
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

-- Process outline items recursively into Org headlines
local function process_outline_list(bullet_list, level)
  local result_blocks = {}
  
  for _, item_blocks in ipairs(bullet_list.content) do
    if #item_blocks == 0 then
      -- Skip empty blocks (do not emit spare *)
    else
      local first_block = item_blocks[1]
      local visual_level = nil
      local raw_inlines = nil
      
      -- Check special alert blocks (#+BEGIN_TIP etc.)
      local special = process_special_block(first_block)
      if special then
        table.insert(result_blocks, special)
      elseif first_block.t == "Header" then
        visual_level = first_block.level
        raw_inlines = first_block.content
      elseif first_block.t == "Figure" and first_block.content and #first_block.content > 0 then
        local inner = first_block.content[1]
        if inner.t == "Plain" or inner.t == "Para" then
          raw_inlines = inner.content
        else
          table.insert(result_blocks, first_block)
        end
      elseif first_block.t == "Para" or first_block.t == "Plain" then
        local str = inlines_to_text(first_block.content)
        local hashes = str:match("^(#+)%s+")
        if hashes then
          visual_level = #hashes
          raw_inlines = strip_leading_hashes(first_block.content)
        else
          raw_inlines = first_block.content
        end
      else
        table.insert(result_blocks, first_block)
      end
      
      if raw_inlines then
        local kept, props, plan = separate_properties_from_inlines(raw_inlines)
        if visual_level then
          props["heading"] = { val = tostring(visual_level), raw_key = "heading" }
        end
        
        -- Check subsequent blocks for continuation properties/planning
        local next_idx = 2
        local remaining_body_blocks = {}
        while next_idx <= #item_blocks do
          local b = item_blocks[next_idx]
          if b.t == "Para" or b.t == "Plain" then
            local b_kept, b_props, b_plan = separate_properties_from_inlines(b.content)
            for k, v in pairs(b_props) do props[k] = v end
            if b_plan.scheduled then plan.scheduled = b_plan.scheduled end
            if b_plan.deadline then plan.deadline = b_plan.deadline end
            if #b_kept > 0 then
              b.content = transform_inlines(b_kept)
              table.insert(remaining_body_blocks, b)
            end
          else
            table.insert(remaining_body_blocks, b)
          end
          next_idx = next_idx + 1
        end

        local task_state, priority, cleaned_inlines = extract_task_and_priority(kept)
        local tag_cleaned = extract_headline_tags(cleaned_inlines)
        local transformed = transform_inlines(tag_cleaned)
        local title_str = inlines_to_org_text(transformed)
        
        -- If the bullet line had only properties (e.g. id::) and the text was on the next line
        if title_str == "" and #remaining_body_blocks > 0 then
          local next_b = remaining_body_blocks[1]
          if next_b.t == "Para" or next_b.t == "Plain" then
            title_str = inlines_to_org_text(next_b.content)
            table.remove(remaining_body_blocks, 1)
          elseif next_b.t == "OrderedList" and #next_b.content > 0 then
            local first_item = next_b.content[1]
            if #first_item > 0 and (first_item[1].t == "Plain" or first_item[1].t == "Para") then
              title_str = "3. " .. inlines_to_org_text(first_item[1].content)
              table.remove(first_item, 1)
              if #first_item == 0 then
                table.remove(next_b.content, 1)
                if #next_b.content == 0 then
                  table.remove(remaining_body_blocks, 1)
                end
              end
            end
          end
        end

        local stars = string.rep("*", level)
        local parts = { stars }
        if task_state then table.insert(parts, task_state) end
        if priority then table.insert(parts, priority) end
        if title_str ~= "" then table.insert(parts, title_str) end
        local headline_line = table.concat(parts, " ")
        
        local plan_line = nil
        local plan_parts = {}
        if plan.scheduled then table.insert(plan_parts, "SCHEDULED: " .. plan.scheduled) end
        if plan.deadline then table.insert(plan_parts, "DEADLINE: " .. plan.deadline) end
        if #plan_parts > 0 then plan_line = table.concat(plan_parts, " ") end
        
        local drawer = build_block_drawer(props)

        local is_empty = (title_str == "" or is_empty_inlines(kept))
          and not task_state
          and not priority
          and not visual_level
          and not plan_line
          and not drawer

        if not is_empty then
          local out_lines = { headline_line }
          if plan_line then table.insert(out_lines, plan_line) end
          if drawer then table.insert(out_lines, drawer) end
          table.insert(result_blocks, pandoc.RawBlock("org", table.concat(out_lines, "\n")))
          
          for _, b in ipairs(remaining_body_blocks) do
            if b.t == "BulletList" then
              local children = process_outline_list(b, level + 1)
              for _, cb in ipairs(children) do table.insert(result_blocks, cb) end
            else
              table.insert(result_blocks, b)
            end
          end
        else
          -- Empty block: if it has child lists, promote children to current level
          for _, b in ipairs(remaining_body_blocks) do
            if b.t == "BulletList" then
              local children = process_outline_list(b, level)
              for _, cb in ipairs(children) do table.insert(result_blocks, cb) end
            else
              table.insert(result_blocks, b)
            end
          end
        end
      else
        for idx = 2, #item_blocks do
          local b = item_blocks[idx]
          if b.t == "BulletList" then
            local children = process_outline_list(b, level + 1)
            for _, cb in ipairs(children) do table.insert(result_blocks, cb) end
          else
            table.insert(result_blocks, b)
          end
        end
      end
    end
  end
  
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
      local outlines = process_outline_list(block, 1)
      for _, ob in ipairs(outlines) do
        table.insert(new_blocks, ob)
      end
    elseif block.t == "Header" then
      local visual_level = block.level
      local props = { heading = { val = tostring(visual_level), raw_key = "heading" } }
      local task_state, priority, cleaned = extract_task_and_priority(block.content)
      local tag_cleaned = extract_headline_tags(cleaned)
      local transformed = transform_inlines(tag_cleaned)
      local title_str = inlines_to_org_text(transformed)
      local stars = "*"
      local parts = { stars }
      if task_state then table.insert(parts, task_state) end
      if priority then table.insert(parts, priority) end
      if title_str ~= "" then table.insert(parts, title_str) end
      local hl = table.concat(parts, " ")
      local drawer = build_block_drawer(props)
      local lines = { hl }
      if drawer then table.insert(lines, drawer) end
      table.insert(new_blocks, pandoc.RawBlock("org", table.concat(lines, "\n")))
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
