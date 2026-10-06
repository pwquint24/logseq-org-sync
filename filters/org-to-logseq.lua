-- org-to-logseq.lua: Pandoc Lua filter to convert Org-roam Org mode to Logseq Markdown.
-- Focuses on restoring Logseq-specific outliner structures, properties, and embeds.

local function trim(s)
  if not s then return "" end
  return (s:gsub("^%s*(.-)%s*$", "%1"))
end

local function format_logseq_tags(filetags)
  if not filetags or filetags == "" then return nil end
  local tags = {}
  for tag in filetags:gmatch("[^:]+") do
    if tag ~= "" then
      table.insert(tags, tag)
    end
  end
  if #tags == 0 then return nil end
  return table.concat(tags, ", ")
end

local function format_logseq_aliases(aliases_str)
  if not aliases_str or aliases_str == "" then return nil end
  local aliases = {}
  for alias in aliases_str:gmatch('"(.-)"') do
    table.insert(aliases, alias)
  end
  if #aliases == 0 then return nil end
  return table.concat(aliases, ", ")
end

-- Reverse task state mapping
local function reverse_task_state(kw)
  local kw_map = {
    TODO = "LATER",
    NEXT = "NOW",
    STARTED = "DOING",
    WAIT = "WAITING",
    CANCELLED = "CANCELLED"
  }
  return kw_map[kw] or kw
end

-- Process inline elements: Link, Span (anchors), etc.
function Inlines(inlines)
  local new_inlines = {}
  
  for _, inline in ipairs(inlines) do
    if inline.t == "Link" then
      local target = inline.target
      local label = pandoc.utils.stringify(inline.content)
      local id_ref = target:match("^id:(.+)$")
      
      if label == "#embed" then
        if id_ref then
          table.insert(new_inlines, pandoc.RawInline("markdown", string.format("{{embed ((%s))}}", id_ref)))
        else
          table.insert(new_inlines, pandoc.RawInline("markdown", string.format("{{embed [[%s]]}}", target)))
        end
      elseif id_ref then
        if label == "" or label == target or label == "id:" .. id_ref then
          table.insert(new_inlines, pandoc.RawInline("markdown", string.format("((%s))", id_ref)))
        else
          table.insert(new_inlines, pandoc.RawInline("markdown", string.format("[%s](((%s)))", label, id_ref)))
        end
      else
        -- Standard links
        if label == "" or label == target then
           table.insert(new_inlines, pandoc.RawInline("markdown", string.format("[[%s]]", target)))
        else
           table.insert(new_inlines, pandoc.RawInline("markdown", string.format("[%s]([[%s]])", label, target)))
        end
      end
    elseif inline.t == "Span" then
      -- Pandoc Org reader turns [[Page]] into Span with target attribute sometimes,
      -- and anchors <<uuid>> into Span with ID.
      local target = inline.attributes["target"]
      if target then
        local label = pandoc.utils.stringify(inline.content)
        -- Support Emph wrapper that Pandoc adds sometimes
        local is_embed = (label == "#embed")
        if not is_embed and inline.content[1] and inline.content[1].t == "Emph" then
           is_embed = (pandoc.utils.stringify(inline.content[1]) == "#embed")
        end
        
        if is_embed then
          table.insert(new_inlines, pandoc.RawInline("markdown", string.format("{{embed [[%s]]}}", target)))
        elseif label == "" or label == target then
          table.insert(new_inlines, pandoc.RawInline("markdown", string.format("[[%s]]", target)))
        else
          table.insert(new_inlines, pandoc.RawInline("markdown", string.format("[%s]([[%s]])", label, target)))
        end
      elseif inline.identifier ~= "" then
        -- This is an anchor <<uuid>>
        table.insert(new_inlines, pandoc.RawInline("markdown", string.format("\n  id:: %s", inline.identifier)))
      else
        table.insert(new_inlines, inline)
      end
    else
      table.insert(new_inlines, inline)
    end
  end
  
  return new_inlines
end

-- Top-level Pandoc transformation
function Pandoc(doc)
  local filename = PANDOC_STATE.input_files[1]
  local page_props = {}
  local title = ""
  
  if filename and filename ~= "-" then
    local f = io.open(filename, "r")
    if f then
      local content = f:read("*all")
      f:close()
      
      -- Extract :PROPERTIES: drawer
      local props_text = content:match(":PROPERTIES:\n(.-):END:")
      if props_text then
        for k, v in props_text:gmatch(":(%w+):%s*(.-)\n") do
          local kl = k:lower()
          if kl == "id" then page_props["id"] = trim(v)
          elseif kl == "roam_aliases" then page_props["alias"] = format_logseq_aliases(v)
          else page_props[kl] = trim(v)
          end
        end
      end
      
      -- Extract #+title and #+filetags
      title = content:match("\n#%+title:%s*(.-)\n") or content:match("^#%+title:%s*(.-)\n") or ""
      local tags_text = content:match("\n#%+filetags:%s*(.-)\n") or content:match("^#%+filetags:%s*(.-)\n")
      if tags_text then
        page_props["tags"] = format_logseq_tags(tags_text)
      end
    end
  end
  
  local new_blocks = {}
  
  -- 2. Build Logseq page properties block
  local prop_lines = {}
  if title ~= "" then table.insert(prop_lines, "title:: " .. title) end
  if page_props["id"] then table.insert(prop_lines, "id:: " .. page_props["id"]) end
  if page_props["alias"] then table.insert(prop_lines, "alias:: " .. page_props["alias"]) end
  if page_props["tags"] then table.insert(prop_lines, "tags:: " .. page_props["tags"]) end
  for k, v in pairs(page_props) do
    if k ~= "id" and k ~= "alias" and k ~= "tags" and k ~= "title" then
      table.insert(prop_lines, k .. ":: " .. v)
    end
  end
  
  if #prop_lines > 0 then
    table.insert(new_blocks, pandoc.Plain(pandoc.RawInline("markdown", table.concat(prop_lines, "\n") .. "\n")))
  end
  
  -- 3. Process blocks
  for _, b in ipairs(doc.blocks) do
    -- Suppress redundant metadata blocks
    if b.t == "RawBlock" and b.format == "org" then
      local text = b.text
      if text:match("^#%+filetags:") or text:match("^#%+title:") or text:match("^:PROPERTIES:") then
        -- Skip
      else
        table.insert(new_blocks, pandoc.BulletList({ {b} }))
      end
      
    elseif b.t == "Header" then
      local level = b.level
      local hashes = string.rep("#", level)
      
      -- Reconstruct header content, extracting Task and Priority
      local header_inlines = b.content
      local task_state = nil
      local priority = nil
      local clean_inlines = {}
      
      for _, inl in ipairs(header_inlines) do
        if inl.t == "Span" and (inl.classes:includes("todo") or inl.classes:includes("NEXT")) then
          task_state = reverse_task_state(pandoc.utils.stringify(inl))
        elseif inl.t == "Str" and (inl.text == "NEXT" or inl.text == "TODO") then
           task_state = reverse_task_state(inl.text)
        elseif inl.t == "Str" and inl.text:match("^%[#[ABC]%]$") then
          priority = inl.text
        elseif inl.t == "Space" and (#clean_inlines == 0) then
          -- skip leading space
        else
          table.insert(clean_inlines, inl)
        end
      end
      
      local prefix = "- "
      if task_state then prefix = prefix .. task_state .. " " end
      if priority then prefix = prefix .. priority .. " " end
      prefix = prefix .. hashes .. " "
      
      local header_props = {}
      if b.identifier ~= "" and not b.identifier:match("^h%d") then
        header_props["id"] = b.identifier
      end
      for k, v in pairs(b.attributes) do
        header_props[k] = v
      end
      
      local header_text = prefix .. pandoc.utils.stringify(clean_inlines)
      local header_lines = { header_text }
      for k, v in pairs(header_props) do
        table.insert(header_lines, string.format("  %s:: %s", k, v))
      end
      
      table.insert(new_blocks, pandoc.Plain(pandoc.RawInline("markdown", table.concat(header_lines, "\n"))))
      
    elseif b.t == "BulletList" then
      table.insert(new_blocks, b)
    elseif b.t == "Para" or b.t == "Plain" then
      table.insert(new_blocks, pandoc.BulletList({ {b} }))
    else
      table.insert(new_blocks, b)
    end
  end
  
  return pandoc.Pandoc(new_blocks, doc.meta)
end
