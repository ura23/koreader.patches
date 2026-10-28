<details>
<summary><b>Early Turn — KOReader user patch</b></summary>

A page turn should not wait for the finger to be lifted. This patch turns the
page in the reader — or a screenful in a full-screen list — as soon as a
horizontal swipe has travelled **35 dp**, while the finger is still on the
screen.

## Features

- One turn per gesture — a release or swipe that follows an already handed
  pan does not turn a second time.
- Works in the reader (page mode) and in every full-screen, paginated list:
  table of contents, bookmarks, history, collections, search results, OPDS,
  folder shortcuts and the file browser.
- Respects your settings: scroll mode, page flipping, zoomed pages, popout
  menus, `page_turns_disable_swipe`, and the swipe-to-go-back /
  swipe-to-follow-link gestures are all left alone.
- RTL and mirrored UI layouts behave exactly like the built-in swipe.

## Installation

1. Copy `2-earlyturn.lua` to `koreader/patches/` on your device.
2. Enable it in **Tools → More tools → Patch management**.

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

## Requirements

KOReader with the user-patch mechanism (`koreader/patches/`, runlevel `2`) and
a touch screen. Tested on a Kindle Paperwhite 11 running KOReader in
landscape; nothing in the patch is Kindle-specific.

</details>
