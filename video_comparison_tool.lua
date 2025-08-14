local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'
local assdraw = require 'mp.assdraw'

local modes = {
    { name = "Grid", layout = "grid" },
    { name = "Cropped Horizontal", layout = "h_centered" },
    { name = "Cropped Vertical", layout = "v_centered" },
    { name = "Progressive Horizontal", layout = "h_progressive" },
    { name = "Progressive Vertical", layout = "v_progressive" },
}

local menu_index = 1
local menu_active = false
local original_layout = nil
local current_font_size = nil

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

local function generate_info_text(vid_index, filename)
    local tp = text_position_params()
    local filename_esc = escape_special_chars(filename)
    local x_title = "(w-text_w)/2"
    local x_info = "(w-text_w)/2"
    local text_color = "white@0.7"
    local border_color = "black@0.7"

    local framerate = mp.get_property_number("estimated-vf-fps", "60")

    return string.format(
        "[vid%d]drawtext=text='%s':x=%s:y=%d:fontsize=%d:fontcolor=%s:bordercolor=%s:borderw=%d," ..
        "drawtext=text='%%{eif\\:t*%s+0.1\\:d}':x=%s:y=%s:fontsize=%d:fontcolor=%s:bordercolor=%s:borderw=%d," ..
        "drawtext=text='%%{pts\\:hms}':x=%s:y=%s:fontsize=%d:fontcolor=%s:bordercolor=%s:borderw=%d",
        vid_index, filename_esc,
        x_title, tp.title_y, tp.font_size, text_color, border_color, tp.shadow,
        framerate, x_info, tp.frame_y, tp.font_size, text_color, border_color, tp.shadow,
        x_info, tp.time_y, tp.font_size, text_color, border_color, tp.shadow
    )
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
        local text_overlay = generate_info_text(i, filename) .. string.format("[v%d];", i)
        filter_chain = filter_chain .. text_overlay
    end

    if video_count == 1 then
        filter_chain = filter_chain .. "[v1]copy[vo]"
    elseif video_count == 2 then
        filter_chain = filter_chain .. "[v1][v2]hstack=inputs=2[vo]"
    elseif video_count == 3 then
        filter_chain = filter_chain .. "[v1][v2]hstack=inputs=2[tmp1];[v3]pad=w=2*iw:h=ih:x=(ow-iw)/2:y=0[scaled_v3];[tmp1][scaled_v3]vstack=inputs=2[vo]"
    elseif video_count == 4 then
        filter_chain = filter_chain .. "[v1][v2]hstack=inputs=2[tmp1];[v3][v4]hstack=inputs=2[tmp2];[tmp1][tmp2]vstack=inputs=2[vo]"
    elseif video_count == 5 then
        filter_chain = filter_chain .. "[v1][v2][v3]hstack=inputs=3[tmp1];[v4][v5]hstack=inputs=2[tmp2_sm];[tmp2_sm]pad=w=3*iw/2:h=ih:x=(ow-iw)/2:y=0[tmp2];[tmp1][tmp2]vstack=inputs=2[vo]"
    elseif video_count == 6 then
        filter_chain = filter_chain .. "[v1][v2][v3]hstack=inputs=3[tmp1];[v4][v5][v6]hstack=inputs=3[tmp2];[tmp1][tmp2]vstack=inputs=2[vo]"
    elseif video_count == 7 then
        filter_chain = filter_chain .. "[v1][v2]hstack=inputs=2[tmp1_sm];[tmp1_sm]pad=w=3*iw/2:h=ih:x=(ow-iw)/2:y=0[tmp1];[v3][v4][v5]hstack=inputs=3[tmp2];[v6][v7]hstack=inputs=2[tmp3_sm];[tmp3_sm]pad=w=3*iw/2:h=ih:x=(ow-iw)/2:y=0[tmp3];[tmp1][tmp2][tmp3]vstack=inputs=3[vo]"
    elseif video_count == 8 then
        filter_chain = filter_chain .. "[v1][v2][v3]hstack=inputs=3[tmp1];[v4][v5][v6]hstack=inputs=3[tmp2];[v7][v8]hstack=inputs=2[tmp3_sm];[tmp3_sm]pad=w=3*iw/2:h=ih:x=(ow-iw)/2:y=0[tmp3];[tmp1][tmp2]vstack=inputs=2[tmp4];[tmp4][tmp3]vstack=inputs=2[vo]"
    elseif video_count == 9 then
        filter_chain = filter_chain .. "[v1][v2][v3]hstack=inputs=3[tmp1];[v4][v5][v6]hstack=inputs=3[tmp2];[v7][v8][v9]hstack=inputs=3[tmp3];[tmp1][tmp2][tmp3]vstack=inputs=3[vo]"
    else
        local inputs = {}
        for i = 1, video_count do
            table.insert(inputs, "[v" .. i .. "]")
        end
        filter_chain = filter_chain .. table.concat(inputs) .. string.format("hstack=inputs=%d[vo]", video_count)
    end 

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
    filter_chain = filter_chain .. info_text .. "[vo]"
    
    msg.info(filter_chain)
    return filter_chain
end

local function update_menu_entries()
    while #modes > 5 do
        table.remove(modes)
    end
    
    local video_count = count_video_tracks()
    for i = 1, video_count do
        local filename = get_filename(i)
        table.insert(modes, { name = string.format("Video %d: %s", i, filename), layout = i })
    end
end

mp.register_event("file-loaded", function()
    original_layout = mp.get_property("lavfi-complex")
    msg.info("Original layout stored: " .. (original_layout or "none"))
    
    update_menu_entries()
    
    if not original_layout or original_layout == "" then
        local grid = build_grid_layout()
        if grid then
            mp.set_property("lavfi-complex", grid)
            msg.info("Applied default grid layout")
        end
    end
end)

local function apply_mode()
    local selected = modes[menu_index]
    
    if selected.layout == "grid" then
        local grid = build_grid_layout()
        if grid then
            mp.set_property("lavfi-complex", grid)
            mp.osd_message("Switched to Grid View", 2)
        else
            mp.osd_message("Could not create grid layout", 2)
        end
    elseif selected.layout == "h_centered" then
        local layout = build_h_centered_layout()
        if layout then
            mp.set_property("lavfi-complex", layout)
            mp.osd_message("Switched to Horizontal Center Crop View", 2)
        end
    elseif selected.layout == "v_centered" then
        local layout = build_v_centered_layout()
        if layout then
            mp.set_property("lavfi-complex", layout)
            mp.osd_message("Switched to Vertical Center Crop View", 2)
        end
    elseif selected.layout == "h_progressive" then
        local layout = build_h_progressive_layout()
        if layout then
            mp.set_property("lavfi-complex", layout)
            mp.osd_message("Switched to Horizontal Progressive View", 2)
        end
    elseif selected.layout == "v_progressive" then
        local layout = build_v_progressive_layout()
        if layout then
            mp.set_property("lavfi-complex", layout)
            mp.osd_message("Switched to Vertical Progressive View", 2)
        end
    else
        local idx = selected.layout
        if type(idx) == "number" then
            local single = build_single_video(idx)
            if single then
                mp.set_property("lavfi-complex", single)
                mp.osd_message("Switched to " .. selected.name, 2)
            end
        end
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

    for i, item in ipairs(modes) do
        local selected = (i == menu_index)
        local prefix = selected and "→ " or "   "
        local color = selected and "{\\1c&HFFFFFF&}" or "{\\1c&HCCCCCC&}"
        ass:append(string.format("%s%s%s\\N", color, prefix, item.name))
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
    update_menu_entries()
    if menu_index < 1 then menu_index = 1 end
    if menu_index > #modes then menu_index = #modes end
    
    render_menu()
    mp.add_forced_key_binding("UP", "layout-up", layout_up)
    mp.add_forced_key_binding("DOWN", "layout-down", layout_down)
    mp.add_forced_key_binding("ENTER", "layout-select", layout_select)
    mp.add_forced_key_binding("ESC", "layout-cancel", layout_cancel)
end

mp.add_key_binding("Z", "reset-view", function()
    local grid = build_grid_layout()
    if grid then
        mp.set_property("lavfi-complex", grid)
        mp.osd_message("Reset to Grid View", 2)
    end
end)

mp.add_key_binding("X", "show-layout-menu", show_layout_menu)
