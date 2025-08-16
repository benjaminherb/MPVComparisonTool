local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'

local modes = {
    { 
        name = "Overview", 
        layout = "grid"
    },
    { 
        name = "Grid", 
        submodes = {
            { name = "Center Crop", layout = "grid_centered" },
            { name = "Progressive", layout = "grid_progressive" }
        }
    },
    { 
        name = "Horizontal", 
        submodes = {
            { name = "Center Crop", layout = "h_centered" },
            { name = "Progressive", layout = "h_progressive" }
        }
    },
    { 
        name = "Vertical", 
        submodes = {
            { name = "Center Crop", layout = "v_centered" },
            { name = "Progressive", layout = "v_progressive" }
        }
    }
}

local menu_index = 1
local global_submode_index = 1  
local menu_active = false
local original_layout = nil
local current_font_size = nil
local overlay_active = true
local intro_timer = nil
local intro_active = false
local intro_overlay = nil
local intro_bindings_added = false

local function count_video_tracks()
    local count = 0
    local track_list = mp.get_property_native("track-list", {})
    
    for _, track in ipairs(track_list) do
        if track.type == "video" and track.selected then
            count = count + 1
        end
    end
    
    if count == 0 then count = 1 end
    return count
end

-- Treat trivial startup graphs as placeholders so we can still apply our grid
local function is_placeholder_layout(layout)
    if not layout or layout == "" then return true end
    local normalized = layout:gsub("%s+", "")
    -- Remove any [vidN]nullsink; occurrences
    normalized = normalized:gsub("%[vid%d+%]nullsink;", "")
    -- After stripping, accept a simple passthrough as placeholder
    return normalized == "" or normalized == "[vid1]copy[vo]"
end

local function get_filename(index)
    if index == 1 then
        local filename = mp.get_property("filename")
        return filename or "video1"
    else
        local external_files = mp.get_property_native("external-files", {})
        if external_files and #external_files >= (index - 1) then
            local filepath = external_files[index - 1]
            local filename = string.match(filepath, "([^/\\]+)$") or "video" .. index
            return filename
        end
        return "video" .. index
    end
end

local function calculate_font_size()
    local width = mp.get_property_number("width", 1920)
    local height = mp.get_property_number("height", 1080)
    
    if not width or width == 0 or not height or height == 0 then
        msg.warn("Invalid video dimensions, using default font size")
        return 24
    end
    
    local base_dimension = math.max(width, height)
    local font_size = math.max(math.floor(base_dimension * 0.01), 16)
    
    current_font_size = font_size
    msg.debug("Calculated font size: " .. font_size)
    return font_size
end

local function text_position_params()
    local font_size = current_font_size or calculate_font_size()
    local padding = math.max(font_size * 0.1, 5)
    local line_height = font_size * 1.2
    
    return {
        font_size = font_size,
        padding = padding,
        title_y = padding,
        frame_y = "h-" .. (padding + line_height*2),
        time_y = "h-" .. (padding + line_height),
        shadow = math.max(font_size / 10, 2)
    }
end

local function escape_special_chars(str)
    return str:gsub(":", "\\:"):gsub("'", "\\'"):gsub("/", "\\/")
end

local function generate_info_text(vid_index, filename, font_multiplier)
    if not overlay_active then
        return string.format("[vid%d]copy", vid_index)
    end

    local tp = text_position_params()
    local filename_esc = escape_special_chars(filename)
    local x_title = "(w-text_w)/2"
    local text_color = "white@0.7"
    local border_color = "black@0.7"
    
    -- Apply font multiplier for grid layouts
    local font_size = tp.font_size
    if font_multiplier then
        font_size = math.max(math.floor(font_size * font_multiplier), 16)
    end
    local shadow = math.max(font_size / 10, 2)

    -- Only show filename, no frame/time counters
    local base = string.format(
        "[vid%d]drawtext=text='%s':x=%s:y=%d:fontsize=%d:fontcolor=%s:bordercolor=%s:borderw=%d",
        vid_index, filename_esc,
        x_title, tp.title_y, font_size, text_color, border_color, shadow
    )

    return base
end

local function generate_global_counter()
    if not overlay_active then
        return ""
    end

    local tp = text_position_params()
    local x_info = "(w-text_w)/2"
    local text_color = "white@0.7"
    local border_color = "black@0.7"

    -- Use numeric default for fps to avoid implicit coercion
    local framerate = mp.get_property_number("estimated-vf-fps", 60)

    local counter = string.format(
        "drawtext=text='%%{eif\\:t*%s+0.1\\:d}':x=%s:y=%s:fontsize=%d:fontcolor=%s:bordercolor=%s:borderw=%d," ..
        "drawtext=text='%%{pts\\:hms}':x=%s:y=%s:fontsize=%d:fontcolor=%s:bordercolor=%s:borderw=%d",
        framerate, x_info, tp.frame_y, tp.font_size, text_color, border_color, tp.shadow,
        x_info, tp.time_y, tp.font_size, text_color, border_color, tp.shadow
    )

    return counter
end

-- Ensure a semicolon is present when concatenating filter steps
local function ensure_sep(chain)
    if #chain == 0 or chain:sub(-1) == ';' then return chain end
    return chain .. ';'
end

-- Build and show a startup intro overlay for ~20 seconds
local function ass_escape(s)
    return (s:gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"))
end

local function path_basename(p)
    if not p or p == '' then return '' end
    return p:match("[^/\\]+$") or p
end

local function remove_intro()
    if intro_timer then intro_timer:kill(); intro_timer = nil end
    mp.set_osd_ass(0, 0, "")
    intro_active = false
end

local function show_startup_intro()
    local main_path = mp.get_property("path") or (mp.get_property("filename") or "")
    local externals = mp.get_property_native("external-files", {}) or {}
    local videos = { main_path }
    for _, p in ipairs(externals) do table.insert(videos, p) end

    local n = #videos
    local lines = { string.format("Loaded %d videos", n) }
    for i, v in ipairs(videos) do
        local tag = string.format("[%d]", i)
        table.insert(lines, string.format("%s  %s", tag, path_basename(v)))
    end
    table.insert(lines, " ")
    table.insert(lines, "X: Menu    P: Pixel    O: Overlay")

    local width = mp.get_property_number("width", 1920)
    local height = mp.get_property_number("height", 1080)
    local base_font_size = 42
    local gap = math.min(width, height) * 0.02

    local ass = assdraw.ass_new()
    ass:new_event()
    ass:pos(gap, gap)

    local alpha_full = "{\\1a&H00&}"
    local alpha_bright = "{\\1a&H20&}"
    
    for i = 1, #lines do
        local text = ass_escape(lines[i])
        if i == 1 then
            -- First line (header) - bright white
            ass:append(string.format("{\\1c&HFFFFFF&}%s%s", alpha_full, text))
        else
            -- Other lines - slightly dimmer
            ass:append(string.format("{\\1c&HDDDDDD&}%s%s", alpha_bright, text))
        end
        if i < #lines then
            ass:append("\\N")
        end
    end

    mp.set_osd_ass(mp.get_property("osd-width"), mp.get_property("osd-height"), ass.text)
    intro_active = true

    if intro_timer then intro_timer:kill() end
    intro_timer = mp.add_timeout(10, function()
        if intro_active then remove_intro() end
    end)

    local function dismiss()
        if intro_active then remove_intro() end
    end

end

-- Common grid stack builder for 1..9 inputs (exactly mirrors existing logic)
local function build_grid_stack(video_count)
    local chain = ""
    if video_count == 1 then
        chain = chain .. "[v1]copy[vo]"
    elseif video_count == 2 then
        chain = chain .. "[v1][v2]hstack=inputs=2[vo]"
    elseif video_count == 3 then
        chain = chain .. "[v1][v2]hstack=inputs=2[tmp1];[v3]pad=w=2*iw:h=ih:x=(ow-iw)/2:y=0[scaled_v3];[tmp1][scaled_v3]vstack=inputs=2[vo]"
    elseif video_count == 4 then
        chain = chain .. "[v1][v2]hstack=inputs=2[tmp1];[v3][v4]hstack=inputs=2[tmp2];[tmp1][tmp2]vstack=inputs=2[vo]"
    elseif video_count == 5 then
        chain = chain .. "[v1][v2][v3]hstack=inputs=3[tmp1];[v4][v5]hstack=inputs=2[tmp2_sm];[tmp2_sm]pad=w=3*iw/2:h=ih:x=(ow-iw)/2:y=0[tmp2];[tmp1][tmp2]vstack=inputs=2[vo]"
    elseif video_count == 6 then
        chain = chain .. "[v1][v2][v3]hstack=inputs=3[tmp1];[v4][v5][v6]hstack=inputs=3[tmp2];[tmp1][tmp2]vstack=inputs=2[vo]"
    elseif video_count == 7 then
        chain = chain .. "[v1][v2]hstack=inputs=2[tmp1_sm];[tmp1_sm]pad=w=3*iw/2:h=ih:x=(ow-iw)/2:y=0[tmp1];[v3][v4][v5]hstack=inputs=3[tmp2];[v6][v7]hstack=inputs=2[tmp3_sm];[tmp3_sm]pad=w=3*iw/2:h=ih:x=(ow-iw)/2:y=0[tmp3];[tmp1][tmp2][tmp3]vstack=inputs=3[vo]"
    elseif video_count == 8 then
        chain = chain .. "[v1][v2][v3]hstack=inputs=3[tmp1];[v4][v5][v6]hstack=inputs=3[tmp2];[v7][v8]hstack=inputs=2[tmp3_sm];[tmp3_sm]pad=w=3*iw/2:h=ih:x=(ow-iw)/2:y=0[tmp3];[tmp1][tmp2]vstack=inputs=2[tmp4];[tmp4][tmp3]vstack=inputs=2[vo]"
    elseif video_count == 9 then
        chain = chain .. "[v1][v2][v3]hstack=inputs=3[tmp1];[v4][v5][v6]hstack=inputs=3[tmp2];[v7][v8][v9]hstack=inputs=3[tmp3];[tmp1][tmp2][tmp3]vstack=inputs=3[vo]"
    else
        local inputs = {}
        for i = 1, video_count do
            table.insert(inputs, "[v" .. i .. "]")
        end
        chain = chain .. table.concat(inputs) .. string.format("hstack=inputs=%d[vo]", video_count)
    end
    return chain
end

-- Append an optional scale to match the current video params
local function append_scale(chain)
    local target_w = mp.get_property_number("video-params/w", 0)
    local target_h = mp.get_property_number("video-params/h", 0)
    if target_w and target_w > 0 and target_h and target_h > 0 then
        chain = ensure_sep(chain)
        chain = chain .. string.format("[vo]scale=%d:%d[vo]", target_w, target_h)
    else
        msg.warn("Could not determine source video resolution; not scaling grid output")
    end
    return chain
end

-- Append the global frame/time counter if enabled
local function append_global_counter(chain)
    local global_counter = generate_global_counter()
    if global_counter ~= "" then
        chain = ensure_sep(chain)
        chain = chain .. string.format("[vo]%s[vo]", global_counter)
    end
    return chain
end

local function build_grid_layout()
    local video_count = count_video_tracks()
    if video_count < 1 then
        mp.osd_message("No video tracks found", 2)
        return nil
    end
    
    calculate_font_size()
    local filter_chain = ""
    
    for i = 1, video_count do
        local filename = get_filename(i)
        -- Use larger font multiplier for grid layout since videos are smaller
        local text_overlay = generate_info_text(i, filename, 2.0) .. string.format("[v%d];", i)
        filter_chain = filter_chain .. text_overlay
    end

    filter_chain = filter_chain .. build_grid_stack(video_count)

    filter_chain = append_scale(filter_chain)

    -- Add global frame/time counter at bottom center
    filter_chain = append_global_counter(filter_chain)

    return filter_chain
end

local function build_grid_centered_layout()
    local video_count = count_video_tracks()
    if video_count < 1 then
        mp.osd_message("No video tracks found", 2)
        return nil
    end
    
    calculate_font_size()
    local filter_chain = ""
    
    -- Calculate grid dimensions
    local cols = math.ceil(math.sqrt(video_count))
    local rows = math.ceil(video_count / cols)
    
    for i = 1, video_count do
        local filename = get_filename(i)
        
        if video_count == 1 then
            local text_overlay = generate_info_text(i, filename)
            filter_chain = filter_chain .. text_overlay .. string.format("[v%d];", i)
        else
            -- Crop from center for grid layout
            local crop_width = string.format("iw/%d", cols)
            local crop_height = string.format("ih/%d", rows)
            
            filter_chain = filter_chain .. string.format("[vid%d]crop=%s:%s:(iw-(%s))/2:(ih-(%s))/2[crop%d];", 
                i, crop_width, crop_height, crop_width, crop_height, i)
            
            local crop_info = generate_info_text(0, filename)
            filter_chain = filter_chain .. crop_info:gsub("%[vid%d%]", string.format("[crop%d]", i)) .. 
                           string.format("[v%d];", i)
        end
    end

    filter_chain = filter_chain .. build_grid_stack(video_count)

    filter_chain = append_scale(filter_chain)

    filter_chain = append_global_counter(filter_chain)

    return filter_chain
end

local function build_grid_progressive_layout()
    local video_count = count_video_tracks()
    if video_count < 1 then
        mp.osd_message("No video tracks found", 2)
        return nil
    end
    
    calculate_font_size()
    local filter_chain = ""
    
    -- Calculate grid dimensions
    local cols = math.ceil(math.sqrt(video_count))
    local rows = math.ceil(video_count / cols)
    
    for i = 1, video_count do
        local filename = get_filename(i)
        
        if video_count == 1 then
            local text_overlay = generate_info_text(i, filename)
            filter_chain = filter_chain .. text_overlay .. string.format("[v%d];", i)
        else
            -- Progressive crop for grid layout
            local crop_width, crop_height, x_position, y_position
            
            if video_count == 2 then
                crop_width = "iw/2"
                crop_height = "ih"
                if i == 1 then
                    x_position = "0"
                    y_position = "0"
                else
                    x_position = "iw/2"
                    y_position = "0"
                end
            elseif video_count == 3 then
                crop_width = "iw/2"
                crop_height = "ih/2"
                if i <= 2 then
                    -- Top row
                    x_position = (i == 1) and "0" or "iw/2"
                    y_position = "0"
                else
                    -- Bottom row (single video, centered)
                    x_position = "iw/4"
                    y_position = "ih/2"
                end
            elseif video_count == 4 then
                crop_width = "iw/2"
                crop_height = "ih/2"
                local row = math.floor((i - 1) / 2)
                local col = (i - 1) % 2
                x_position = (col == 0) and "0" or "iw/2"
                y_position = (row == 0) and "0" or "ih/2"
            elseif video_count == 5 then
                crop_width = "iw/3"
                crop_height = "ih/2"
                if i <= 3 then
                    -- Top row (3 videos)
                    local pos = i - 1
                    if pos == 0 then
                        x_position = "0"
                    elseif pos == 1 then
                        x_position = "iw/3"
                    else
                        x_position = "2*iw/3"
                    end
                    y_position = "0"
                else
                    -- Bottom row (2 videos)
                    if i == 4 then
                        x_position = "iw/6"
                    else
                        x_position = "iw/2"
                    end
                    y_position = "ih/2"
                end
            elseif video_count == 6 then
                crop_width = "iw/3"
                crop_height = "ih/2"
                local row = math.floor((i - 1) / 3)
                local col = (i - 1) % 3
                x_position = string.format("%d*iw/3", col)
                y_position = (row == 0) and "0" or "ih/2"
            elseif video_count == 7 then
                -- 2×3×2 layout
                crop_width = "iw/3"
                crop_height = "ih/3"
                if i <= 2 then
                    -- First row (2 videos)
                    x_position = (i == 1) and "iw/6" or "iw/2"
                    y_position = "0"
                elseif i <= 5 then
                    -- Second row (3 videos)
                    local pos = i - 3
                    x_position = string.format("%d*iw/3", pos)
                    y_position = "ih/3"
                else
                    -- Third row (2 videos)
                    x_position = (i == 6) and "iw/6" or "iw/2"
                    y_position = "2*ih/3"
                end
            elseif video_count == 8 then
                -- 3×3×2 layout
                crop_width = "iw/3"
                crop_height = "ih/3"
                if i <= 3 then
                    -- First row (3 videos)
                    x_position = string.format("%d*iw/3", i - 1)
                    y_position = "0"
                elseif i <= 6 then
                    -- Second row (3 videos)
                    x_position = string.format("%d*iw/3", i - 4)
                    y_position = "ih/3"
                else
                    -- Third row (2 videos)
                    x_position = (i == 7) and "iw/6" or "iw/2"
                    y_position = "2*ih/3"
                end
            elseif video_count == 9 then
                crop_width = "iw/3"
                crop_height = "ih/3"
                local row = math.floor((i - 1) / 3)
                local col = (i - 1) % 3
                x_position = string.format("%d*iw/3", col)
                y_position = string.format("%d*ih/3", row)
            else
                -- Default to original logic for other counts
                local cols = math.ceil(math.sqrt(video_count))
                local rows = math.ceil(video_count / cols)
                crop_width = string.format("iw/%d", cols)
                crop_height = string.format("ih/%d", rows)
                
                local col = ((i - 1) % cols)
                local row = math.floor((i - 1) / cols)
                
                if cols == 1 then
                    x_position = "0"
                elseif col == 0 then
                    x_position = "0"
                elseif col == cols - 1 then
                    x_position = string.format("iw-(%s)", crop_width)
                else
                    local ratio = string.format("%f", col / (cols - 1))
                    x_position = string.format("(iw-(%s))*%s", crop_width, ratio)
                end
                
                if rows == 1 then
                    y_position = "0"
                elseif row == 0 then
                    y_position = "0"
                elseif row == rows - 1 then
                    y_position = string.format("ih-(%s)", crop_height)
                else
                    local ratio = string.format("%f", row / (rows - 1))
                    y_position = string.format("(ih-(%s))*%s", crop_height, ratio)
                end
            end
            
            filter_chain = filter_chain .. string.format("[vid%d]crop=%s:%s:%s:%s[crop%d];", 
                i, crop_width, crop_height, x_position, y_position, i)
            
            local crop_info = generate_info_text(0, filename)
            filter_chain = filter_chain .. crop_info:gsub("%[vid%d%]", string.format("[crop%d]", i)) .. 
                           string.format("[v%d];", i)
        end
    end

    filter_chain = filter_chain .. build_grid_stack(video_count)
    filter_chain = append_scale(filter_chain)
    filter_chain = append_global_counter(filter_chain)

    return filter_chain
end

local function build_h_centered_layout()
    local video_count = count_video_tracks()
    if video_count < 1 then
        mp.osd_message("No video tracks found", 2)
        return nil
    end
    
    calculate_font_size()
    local filter_chain = ""
    
    for i = 1, video_count do
        local filename = get_filename(i)
        local crop_width = string.format("iw/%d", video_count)
        
        if video_count == 1 then
            local text_overlay = generate_info_text(i, filename)
            filter_chain = filter_chain .. text_overlay .. string.format("[v%d];", i)
        else
            filter_chain = filter_chain .. string.format("[vid%d]crop=%s:ih:(iw-(%s))/2:0[crop%d];", 
                i, crop_width, crop_width, i)
            
            local crop_info = generate_info_text(0, filename)
            filter_chain = filter_chain .. crop_info:gsub("%[vid%d%]", string.format("[crop%d]", i)) .. 
                           string.format("[v%d];", i)
        end
    end
    
    if video_count == 1 then
        filter_chain = filter_chain .. "[v1]copy[vo]"
    else
        local inputs = {}
        for i = 1, video_count do
            table.insert(inputs, "[v" .. i .. "]")
        end
        filter_chain = filter_chain .. table.concat(inputs) .. string.format("hstack=inputs=%d[vo]", video_count)
    end
    
    filter_chain = append_global_counter(filter_chain)
    
    return filter_chain
end

local function build_v_centered_layout()
    local video_count = count_video_tracks()
    if video_count < 1 then
        mp.osd_message("No video tracks found", 2)
        return nil
    end
    
    calculate_font_size()
    local filter_chain = ""
    
    for i = 1, video_count do
        local filename = get_filename(i)
        local crop_height = string.format("ih/%d", video_count)
        
        if video_count == 1 then
            local text_overlay = generate_info_text(i, filename)
            filter_chain = filter_chain .. text_overlay .. string.format("[v%d];", i)
        else
            filter_chain = filter_chain .. string.format("[vid%d]crop=iw:%s:0:(ih-(%s))/2[crop%d];", 
                i, crop_height, crop_height, i)
            
            local crop_info = generate_info_text(0, filename)
            filter_chain = filter_chain .. crop_info:gsub("%[vid%d%]", string.format("[crop%d]", i)) .. 
                           string.format("[v%d];", i)
        end
    end
    
    if video_count == 1 then
        filter_chain = filter_chain .. "[v1]copy[vo]"
    else
        local inputs = {}
        for i = 1, video_count do
            table.insert(inputs, "[v" .. i .. "]")
        end
        filter_chain = filter_chain .. table.concat(inputs) .. string.format("vstack=inputs=%d[vo]", video_count)
    end
    
    filter_chain = append_global_counter(filter_chain)
    
    return filter_chain
end

local function build_h_progressive_layout()
    local video_count = count_video_tracks()
    if video_count < 1 then
        mp.osd_message("No video tracks found", 2)
        return nil
    end
    
    calculate_font_size()
    local filter_chain = ""
    
    for i = 1, video_count do
        local filename = get_filename(i)
        
        if video_count == 1 then
            local text_overlay = generate_info_text(i, filename)
            filter_chain = filter_chain .. text_overlay .. string.format("[v%d];", i)
        else
            local segment_width = string.format("iw/%d", video_count)
            local x_position
            
            if i == 1 then
                x_position = "0"
            elseif i == video_count then
                x_position = string.format("iw-%s", segment_width)
            else
                local ratio = string.format("%f", (i - 1) / (video_count - 1))
                x_position = string.format("(iw-%s)*%s", segment_width, ratio)
            end
            
            filter_chain = filter_chain .. string.format("[vid%d]crop=%s:ih:%s:0[crop%d];", 
                i, segment_width, x_position, i)
            
            local crop_info = generate_info_text(0, filename)
            filter_chain = filter_chain .. crop_info:gsub("%[vid%d%]", string.format("[crop%d]", i)) .. 
                           string.format("[v%d];", i)
        end
    end
    
    if video_count == 1 then
        filter_chain = filter_chain .. "[v1]copy[vo]"
    else
        local inputs = {}
        for i = 1, video_count do
            table.insert(inputs, "[v" .. i .. "]")
        end
        filter_chain = filter_chain .. table.concat(inputs) .. string.format("hstack=inputs=%d[vo]", video_count)
    end
    
    filter_chain = append_global_counter(filter_chain)
    
    return filter_chain
end

local function build_v_progressive_layout()
    local video_count = count_video_tracks()
    if video_count < 1 then
        mp.osd_message("No video tracks found", 2)
        return nil
    end
    
    calculate_font_size()
    local filter_chain = ""
    
    for i = 1, video_count do
        local filename = get_filename(i)
        
        if video_count == 1 then
            local text_overlay = generate_info_text(i, filename)
            filter_chain = filter_chain .. text_overlay .. string.format("[v%d];", i)
        else
            local segment_height = string.format("ih/%d", video_count)
            local y_position
            
            if i == 1 then
                y_position = "0"
            elseif i == video_count then
                y_position = string.format("ih-%s", segment_height)
            else
                local ratio = string.format("%f", (i - 1) / (video_count - 1))
                y_position = string.format("(ih-%s)*%s", segment_height, ratio)
            end
            
            filter_chain = filter_chain .. string.format("[vid%d]crop=iw:%s:0:%s[crop%d];", 
                i, segment_height, y_position, i)
            
            local crop_info = generate_info_text(0, filename)
            filter_chain = filter_chain .. crop_info:gsub("%[vid%d%]", string.format("[crop%d]", i)) .. 
                           string.format("[v%d];", i)
        end
    end
    
    if video_count == 1 then
        filter_chain = filter_chain .. "[v1]copy[vo]"
    else
        local inputs = {}
        for i = 1, video_count do
            table.insert(inputs, "[v" .. i .. "]")
        end
        filter_chain = filter_chain .. table.concat(inputs) .. string.format("vstack=inputs=%d[vo]", video_count)
    end
    
    -- Add global frame/time counter at bottom center
    filter_chain = append_global_counter(filter_chain)
    
    return filter_chain
end

local function build_single_video(index)
    local video_count = count_video_tracks()
    if index > video_count then
        mp.osd_message("Video " .. index .. " does not exist", 2)
        return nil
    end
    
    calculate_font_size()
    local filename = get_filename(index)
    local filter_chain = ""
    
    for i = 1, video_count do
        if i ~= index then
            filter_chain = filter_chain .. string.format("[vid%d]nullsink;", i)
        end
    end
    
    local info_text = generate_info_text(index, filename)
    filter_chain = filter_chain .. info_text .. string.format("[single%d];", index)
    
    local global_counter = generate_global_counter()
    if global_counter ~= "" then
        filter_chain = filter_chain .. string.format("[single%d]%s[vo]", index, global_counter)
    else
        filter_chain = filter_chain .. string.format("[single%d]copy[vo]", index)
    end
    
    msg.info(filter_chain)
    return filter_chain
end

local function update_menu_entries()
    -- Remove any individual video entries that might have been added
    while #modes > 4 do
        table.remove(modes)
    end
    
    local video_count = count_video_tracks()
    for i = 1, video_count do
        local filename = get_filename(i)
        table.insert(modes, { 
            name = string.format("Video %d: %s", i, filename), 
            layout = i
        })
    end
end

mp.register_event("file-loaded", function()
    original_layout = mp.get_property("lavfi-complex")
    msg.info("Original layout stored: " .. (original_layout or "none"))

    update_menu_entries()

    if is_placeholder_layout(original_layout) then
        local grid = build_grid_layout()
        if grid then
            mp.set_property("lavfi-complex", grid)
            msg.info("Applied default grid layout")
        end
    end
    -- Show intro overlay for ~20 seconds on first load
    show_startup_intro()
end)



local function apply_mode()
    local selected = modes[menu_index]
    local layout = nil
    local message = ""
    
    if selected.submodes then
        -- Mode with submodes - use global submode index
        local submode = selected.submodes[global_submode_index]
        if not submode then
            submode = selected.submodes[1]  -- Fallback to first submode
            global_submode_index = 1
        end
        
        if submode.layout == "grid_centered" then
            layout = build_grid_centered_layout()
        elseif submode.layout == "grid_progressive" then
            layout = build_grid_progressive_layout()
        elseif submode.layout == "h_centered" then
            layout = build_h_centered_layout()
        elseif submode.layout == "h_progressive" then
            layout = build_h_progressive_layout()
        elseif submode.layout == "v_centered" then
            layout = build_v_centered_layout()
        elseif submode.layout == "v_progressive" then
            layout = build_v_progressive_layout()
        else
            local idx = submode.layout
            if type(idx) == "number" then
                layout = build_single_video(idx)
            end
        end
        
        message = selected.name .. " - " .. submode.name
    else
        -- Single mode (Overview)
        if selected.layout == "grid" then
            layout = build_grid_layout()
        else
            local idx = selected.layout
            if type(idx) == "number" then
                layout = build_single_video(idx)
            end
        end
        
        message = selected.name
    end
    
    if layout then
        mp.set_property("lavfi-complex", layout)
    else
        mp.osd_message("Could not create " .. message .. " layout", 2)
    end
end

local function create_ass_menu()
    local width = mp.get_property_number("width", 1920)
    local height = mp.get_property_number("height", 1080)
    local base_font_size = 32

    local gap = math.min(width, height) * 0.05

    local ass = assdraw.ass_new()
    ass:new_event()
    ass:pos(gap, gap) 

    local alpha_full = "{\\1a&H00&}"
    local alpha_dim  = "{\\1a&H80&}"

    for i, item in ipairs(modes) do
        local selected = (i == menu_index)
        local prefix = selected and "→ " or "   "
        local color = selected and "{\\1c&HFFFFFF&}" or "{\\1c&HCCCCCC&}"
        local alpha = selected and alpha_full or alpha_dim
        
        -- Show main category
        ass:append(string.format("%s%s%s%s", color, alpha, prefix, item.name))
        
        -- Show subcategory if this item is selected and has submodes
        if selected and item.submodes then
            local submode = item.submodes[global_submode_index]
            if submode then
                -- Keep arrows dim regardless of selected line alpha
                ass:append(string.format(" - {\\1c&HFFFF00&}%s{\\1c&H666666&\\1a&H80&} ← →", submode.name))
            end
        elseif selected then
            ass:append("{\\1c&H666666&}")
        end
        
        ass:append("\\N")
    end

    return ass.text
end

local function render_menu()
    update_menu_entries()
    mp.set_osd_ass(mp.get_property("osd-width"), mp.get_property("osd-height"), create_ass_menu())
end

local function close_menu()
    mp.remove_key_binding("layout-up")
    mp.remove_key_binding("layout-down")
    mp.remove_key_binding("layout-left")
    mp.remove_key_binding("layout-right")
    mp.remove_key_binding("layout-select")
    mp.remove_key_binding("layout-cancel")
    menu_active = false
    mp.set_osd_ass(0, 0, "")
end

local function layout_up()
    menu_index = menu_index - 1
    if menu_index < 1 then menu_index = #modes end
    render_menu()
end

local function layout_down()
    menu_index = menu_index + 1
    if menu_index > #modes then menu_index = 1 end
    render_menu()
end

local function layout_left()
    local selected = modes[menu_index]
    if selected.submodes then
        global_submode_index = global_submode_index - 1
        if global_submode_index < 1 then global_submode_index = #selected.submodes end
        render_menu()
    end
end

local function layout_right()
    local selected = modes[menu_index]
    if selected.submodes then
        global_submode_index = global_submode_index + 1
        if global_submode_index > #selected.submodes then global_submode_index = 1 end
        render_menu()
    end
end

local function layout_select()
    apply_mode()
    close_menu()
end

local function layout_cancel()
    mp.osd_message("Layout selection cancelled.", 1)
    close_menu()
end

local function show_layout_menu()
    if menu_active then return end
    menu_active = true
    -- Cancel intro overlay when the menu opens
    if intro_active then
    remove_intro()
    end
    update_menu_entries()
    if menu_index < 1 then menu_index = 1 end
    if menu_index > #modes then menu_index = #modes end
    if global_submode_index < 1 then global_submode_index = 1 end
    
    render_menu()
    mp.add_forced_key_binding("UP", "layout-up", layout_up)
    mp.add_forced_key_binding("DOWN", "layout-down", layout_down)
    mp.add_forced_key_binding("LEFT", "layout-left", layout_left)
    mp.add_forced_key_binding("RIGHT", "layout-right", layout_right)
    mp.add_forced_key_binding("ENTER", "layout-select", layout_select)
    mp.add_forced_key_binding("ESC", "layout-cancel", layout_cancel)
end

-- when the menu is not visible
local function global_layout_up()
    if menu_active then
        layout_up()
        return
    end

    update_menu_entries()
    menu_index = menu_index - 1
    if menu_index < 1 then menu_index = #modes end
    apply_mode()
    
    local selected = modes[menu_index]
    local message = selected.name
    if selected.submodes then
        local submode = selected.submodes[global_submode_index]
        if submode then
            message = selected.name .. " - " .. submode.name
        end
    end
    mp.osd_message("Selected: " .. message, 1)
end

local function global_layout_down()
    if menu_active then
        layout_down()
        return
    end

    update_menu_entries()
    menu_index = menu_index + 1
    if menu_index > #modes then menu_index = 1 end
    apply_mode()
    
    local selected = modes[menu_index]
    local message = selected.name
    if selected.submodes then
        local submode = selected.submodes[global_submode_index]
        if submode then
            message = selected.name .. " - " .. submode.name
        end
    end
    mp.osd_message("Selected: " .. message, 1)
end

mp.add_forced_key_binding("UP", "global-layout-up", global_layout_up)
mp.add_forced_key_binding("DOWN", "global-layout-down", global_layout_down)

mp.add_key_binding("X", "show-layout-menu", show_layout_menu)

-- Toggle overlays (on-screen text) with O
local function toggle_overlay()
    overlay_active = not overlay_active
    if menu_active then
        render_menu()
    else
        apply_mode()
    end
    mp.osd_message("overlays: " .. (overlay_active and "on" or "off"), 1)
end

mp.add_key_binding("O", "toggle-overlay", toggle_overlay)

-- Toggle video-unscaled (pixel-perfect) with P
local function toggle_video_unscaled()
    local cur = mp.get_property_native("video-unscaled")
    if cur == nil then cur = false end
    local nextv = not cur
    mp.set_property_native("video-unscaled", nextv)
    mp.osd_message("video-unscaled: " .. (nextv and "on" or "off"), 1)
end

mp.add_key_binding("P", "toggle-video-unscaled", toggle_video_unscaled)
