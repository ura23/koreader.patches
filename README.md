<details>
<summary><b>Early Turn — KOReader user patch</b></summary>

This patch force turning the
pages in the reader — or filemanager — as soon as a
horizontal swipe has travelled **35 dp**, while the finger is still on the
screen.

## Features

- One turn per gesture — a release or swipe that follows an already handed
  pan does not turn a second time.
- Works in the reader (page mode) and in every full-screen, paginated list:
  table of contents, bookmarks, history, collections, search results, OPDS,
  folder shortcuts and the file browser.

## Installation

1. Copy `2-earlyturn.lua` to `koreader/patches/` on your device.

There is no menu of its own: the patch is switched on and off from that
same list.

## Settings

On the first run the patch creates `koreader/settings/earlyturn.lua`:

```lua
return {
    -- Swipe distance (in dp) after which the page turns, without waiting
    -- for the finger to lift. Allowed range: 35 to 200. Lower = more sensitive.
    step_dp = 35,

    -- Also apply early turning to full-screen lists (table of contents,
    -- bookmarks, history, collections, search results, OPDS, file browser).
    lists = true,
}
```

Edit the file to taste; a missing file is recreated with the defaults, and an
out-of-range `step_dp` falls back to 35.

</details>
