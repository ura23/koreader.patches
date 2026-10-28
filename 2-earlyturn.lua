-- v1.6: The "enabled" option is gone: a patch is switched on and off from
--       KOReader's patch menu, so the settings file no longer offers a second
--       master switch (an old "enabled" key in it is simply ignored).
-- v1.5: Settings are read only from settings/earlyturn.lua (the plugin's saved
--       values are no longer used). A missing file is created with the defaults
--       and a short English comment for every option.
-- v1.4: One generic Menu:onGesture hook now covers every full-screen list --
--       the table of contents, bookmarks, history, collections, search results,
--       OPDS, folder shortcuts and the file chooser -- instead of a special
--       case for the file manager. That also drops the lazy FileManager hook,
--       so the patch no longer requires the file manager at startup. New
--       settings key "lists" (default on) turns list support off.
-- v1.3: Threshold and on/off now come from settings/earlyturn.lua, with the
--       plugin's saved values as a fallback; defaults unchanged (35 dp, on).
-- v1.2: Hook FileManager:onSwipeFM lazily on the first file-manager pan instead
--       of requiring the whole file manager at startup; mark the gesture as
--       turned only after the turn itself, so the file-manager hook does not
--       swallow the very turn it is meant to let through.
-- v1.1: Cached the pixel threshold (DPI-aware) and moved the reader/file-manager
--       split out of the hot path, so a pan event allocates nothing but the
--       one-off state table.
-- v1.0: Initial version. Turns a page (reader) or a screenful of the file list
--       (file manager) as soon as a horizontal swipe has travelled 35 dp,
--       instead of waiting for the finger to be lifted. One turn per gesture.
--
-- Patch variant of earlyturn.koplugin: no menu. Instead of registering touch
-- zones it hooks the methods the existing widgets already call, so the reader's
-- own menu/status strips and any configured Gestures edge swipe keep their
-- natural priority over page turning.
local BD = require("ui/bidi")
local DataStorage = require("datastorage")
local Device = require("device")
local Event = require("ui/event")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local ReaderPaging = require("apps/reader/modules/readerpaging")
local ReaderRolling = require("apps/reader/modules/readerrolling")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local Screen = Device.screen

if not Device:isTouchDevice() then return end

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/earlyturn.lua"

-- KOReader reports no movement at all until a pan has travelled 35 dp, so that
-- is the smallest sensible threshold (66 px on a 300 dpi screen).
local STEP_DP_MIN = 35
local STEP_DP_MAX = 200
local DEFAULT_STEP_DP = 35
-- Only clearly horizontal pans count: a cone of about +-27 degrees.
local HORIZONTAL_RATIO = 2

local MODE_READER, MODE_LIST = 1, 2

local SETTINGS
local state -- the gesture being tracked: { x, y, turned = true }
local warned = false
local step_px, step_dpi -- cached threshold in pixels, rebuilt if the DPI changes

local function warn_once(message, err)
    if warned then return end
    warned = true
    logger.warn("earlyturn: " .. message .. ":", err)
end

-- Written to settings/earlyturn.lua when that file does not exist yet.
local DEFAULT_SETTINGS_FILE = [[
-- Early Turn settings. Changes take effect after restarting KOReader.
return {
    -- Swipe distance (in dp) after which the page turns, without waiting
    -- for the finger to lift. Allowed range: 35 to 200. Lower = more sensitive.
    step_dp = 35,

    -- Also apply early turning to full-screen lists (table of contents,
    -- bookmarks, history, collections, search results, OPDS, file browser).
    lists = true,
}
]]

local function create_default_settings_file()
    local f, err = io.open(SETTINGS_FILE, "w")
    if not f then
        logger.warn("earlyturn: cannot create settings file:", err)
        return
    end
    f:write(DEFAULT_SETTINGS_FILE)
    f:close()
end

-- Cached: read from the hot path of every pan event. Only settings/earlyturn.lua
-- is read; if it is missing it is created with the defaults.
local function settings()
    if not SETTINGS then
        local file_settings
        local f = io.open(SETTINGS_FILE, "r")
        if f then
            f:close()
            local ok, result = pcall(dofile, SETTINGS_FILE)
            if ok and type(result) == "table" then
                file_settings = result
            else
                logger.warn("earlyturn: settings file not loaded:", result)
            end
        else
            create_default_settings_file()
        end
        file_settings = file_settings or {}

        local step = tonumber(file_settings.step_dp)
        if not step or step < STEP_DP_MIN or step > STEP_DP_MAX then
            step = DEFAULT_STEP_DP
        end

        SETTINGS = {
            step_dp = step,
            lists = file_settings.lists ~= false,
        }
    end
    return SETTINGS
end

-- scaleByDPI multiplies and rounds; this is read on every pan event, so keep
-- the result until the screen DPI changes (a DPI override in the menu).
local function step_pixels()
    local dpi = Screen:getDPI()
    if not step_px or step_dpi ~= dpi then
        step_dpi = dpi
        step_px = Screen:scaleByDPI(settings().step_dp)
    end
    return step_px
end

-- ── When a turn is allowed ──────────────────────────────────────────────────

local function can_turn_in_reader(ui)
    if not ui.view then return false end
    -- Swipe page turns switched off in "Taps and gestures".
    if G_reader_settings:isTrue("page_turns_disable_swipe") then return false end
    -- Link swipes own the horizontal swipe while they are enabled.
    if G_reader_settings:isTrue("swipe_to_go_back")
        or G_reader_settings:isTrue("swipe_to_follow_nearest_link") then
        return false
    end
    if ui.rolling then
        -- Scroll mode pans the text; only page mode has pages to turn.
        return ui.view.view_mode == "page"
    end
    if ui.paging then
        if ui.view.page_scroll then return false end
        -- While flipping, a pan drags the page instead of turning it.
        if ui.paging.page_flipping_mode or ui.paging.bookmark_flipping_mode then
            return false
        end
        -- A zoomed page is dragged around, not turned.
        if ui.view.zoom_mode and ui.view.zoom_mode ~= "page" then return false end
    end
    return true
end

-- A full-screen, paginated list: the file chooser, the table of contents,
-- bookmarks, history, collections, search results, OPDS, folder shortcuts.
-- Menus shown as a popout over content are left alone, as are one-page lists.
local function is_fullscreen_list(widget)
    if widget.is_popout then return false end
    if not (widget.page and widget.page_num and widget.page_num > 1) then return false end
    local dimen = widget.dimen
    if not dimen then return false end
    return dimen.w >= Screen:getWidth() * 0.9 and dimen.h >= Screen:getHeight() * 0.9
end

local function can_turn_in_list(menu)
    return settings().lists and is_fullscreen_list(menu)
end

-- ── The turn itself ─────────────────────────────────────────────────────────

local function turn_in_reader(ui, raw_direction)
    local direction = BD.flipDirectionIfMirroredUILayout(raw_direction)
    local inverse = ui.view.inverse_reading_order == true
    local forward = (direction == "west") ~= inverse
    ui:handleEvent(Event:new("GotoViewRel", forward and 1 or -1))
end

-- Same directions Menu:onSwipe uses, so RTL mirroring behaves identically.
-- A list wraps around at its last page, as Menu:onNextPage does for swipes.
local function turn_in_list(menu, raw_direction)
    local direction = BD.flipDirectionIfMirroredUILayout(raw_direction)
    if direction == "west" then
        menu:onNextPage()
    elseif direction == "east" then
        menu:onPrevPage()
    end
end

-- ── Gesture core ────────────────────────────────────────────────────────────

-- Returns true when the pan was taken over and a page was turned.
local function handle_pan(ges, mode, target)
    if UIManager._input_gestures_disabled then return false end
    if ges.mousewheel_direction then return false end
    local start, relative = ges.start_pos, ges.relative
    if type(start) ~= "table" or type(relative) ~= "table" then return false end

    -- Compare coordinates rather than building a "x:y" string per event.
    if state and (state.x ~= start.x or state.y ~= start.y) then state = nil end
    -- The rest of a gesture that already turned a page stays ours.
    if state and state.turned then return true end

    local abs_x, abs_y = math.abs(relative.x), math.abs(relative.y)
    if abs_x < step_pixels() then return false end
    if abs_x < HORIZONTAL_RATIO * abs_y then return false end

    local direction = relative.x > 0 and "east" or "west"
    if mode == MODE_READER then
        if not can_turn_in_reader(target) then return false end
        turn_in_reader(target, direction)
    else
        if not can_turn_in_list(target) then return false end
        turn_in_list(target, direction)
    end
    -- Mark the gesture only after the turn: the release handling of the very
    -- same gesture must still see it as unturned.
    state = { x = start.x, y = start.y, turned = true }
    return true
end

-- A pan that errors out must not escape into the input loop.
local function run_pan(ges, mode, target)
    if not target then return false end
    local ok, claimed = pcall(handle_pan, ges, mode, target)
    if not ok then
        warn_once("pan handler failed", claimed)
        return false
    end
    return claimed == true
end

-- Called on swipe and on pan release: consume the event if the page was
-- already turned, so nothing turns twice.
local function release_claim()
    local turned = state and state.turned
    state = nil
    return turned == true
end

-- ── Hooks ───────────────────────────────────────────────────────────────────

-- The reader calls its own onPan from the paging_pan/rolling_pan zones and its
-- own onSwipe from paging_swipe/rolling_swipe, so wrapping the methods needs no
-- zone bookkeeping at all.
local function install_reader_hooks(module)
    local on_pan = module.onPan
    local on_swipe = module.onSwipe
    local on_release = module.onPanRelease

    if on_pan then
        function module:onPan(arg, ges)
            if run_pan(ges, MODE_READER, self.ui) then return true end
            return on_pan(self, arg, ges)
        end
    end

    if on_swipe then
        function module:onSwipe(arg, ges)
            if release_claim() then return true end
            return on_swipe(self, arg, ges)
        end
    end

    if on_release then
        function module:onPanRelease(arg, ges)
            if release_claim() then return true end
            return on_release(self, arg, ges)
        end
    end
end

install_reader_hooks(ReaderPaging)
install_reader_hooks(ReaderRolling)

-- Every full-screen list is a Menu (or a BookList, which extends Menu): the file
-- chooser, the table of contents, bookmarks, history, collections, search
-- results, OPDS, folder shortcuts. A Menu swallows every pan in its own
-- Menu:onPan, so the early turn has to be offered from onGesture, above both the
-- touch zones and the ges_events handlers. Nothing here touches TouchMenu, so
-- the settings menus keep behaving as before.
local function patch_menu()
    local inherited = Menu.onGesture
    local chains = inherited ~= InputContainer.onGesture
    function Menu:onGesture(ev)
        if ev and not UIManager._input_gestures_disabled
            and can_turn_in_list(self) then
            local kind = ev.ges
            if kind == "pan" then
                if not ev.mousewheel_direction and run_pan(ev, MODE_LIST, self) then
                    return true
                end
            elseif kind == "swipe" or kind == "multiswipe" then
                -- The page already turned on the pan stream: keep the lift from
                -- turning one more.
                if release_claim() then return true end
            elseif kind == "pan_release" or kind == "two_finger_pan_release" then
                release_claim()
            end
        end
        if chains then
            return inherited(self, ev)
        end
        return InputContainer.onGesture(self, ev)
    end
end

patch_menu()
