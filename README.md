# SoloLootManager

This script is designed to help those who want to adventure on their own, without boxing, and to somewhat automate their corpse looting, junk selling, and tribute donating.

I wrote this specifically to make my life easier while playing on the Lazarus server.

## Requirements

- MacroQuest (Next) w/ Lua and the `mq\PackageMan.lua` script in the lua directory.

## Installation

Download `SoloLootManager` and extract it into your MQ lua directory.

This script uses an SQLite3 database to store item handling rules, which will be downloaded and setup automatically provided you have the mq/PackageMan script in your lua directory.

## Usage

### Running

Start the script with `/lua run SoloLootManager`.

### Rules

Rules will be added automatically for new items detected in your inventory or an open corpse window, but they will be added in an `unhandled` state, meaning no default action will occur on them and you must explicitly set the action you wish to be applied.

When new rules are added in this way, the `Config` button on the main window will glow red to indicate that there are new rules that need your attention in setting an action.  The `Unhandled Rules` tab in the config window will also glow red.

### Rule Search

Worth noting is that each 'word' in the search will be treated as it's own search, meaning that you can type something like `word energy` to filter down to `Words of Energy`.

### Loot Corpse

Click this button or use the `/slmlootcorpse` command when you have a corpse window open to take the appropriate action on the items in the corpse, as described by the rules you have set.

If the corpse has an item with an `unhandled` rule, then it will not close the corpse window automatically to allow you the chance to set the action in the `Config > Unhandled Rules` section.

### Sell Items

Click this button or use the `/slmsellitems` command when you have a vendor window open to take the appropriate action on the items in your inventory, as described by the rules you have set.

If your inventory has an item with an `unhandled` rule, then it will not close the vendor window automatically to allow you the chance to set the action in the `Config > Unhandled Rules` section.

### Donate Tribute

Click this button or use the `/slmdonatetribute` command when you have a tribute master window open to take the appropriate action on the items in your inventory, as described by the rules you have set.

If your inventory has an item with an `unhandled` rule, then it will not close the tribute master window automatically to allow you the chance to set the action in the `Config > Unhandled Rules` section.

*WARNING* There is a delay between donating an item and selecting the next item.  There is nothing in the UI or the MQ TLO's that I have found to accurately account for this, so an arbitrary delay is used currently.  It may get everything, or it may not.  If not, then simply run it again.

### Slash Commands

| Command | Description |
| --- | --- |
| /slmconfig | Open the Config window |
| /slmlootcorpse | Run the Loot Corpse routine on an open corpse window |
| /slmsellitems | Run the Sell Items routine on an open vendor window |
| /slmdonatetribute | Run the Donate Tribute routine on an open tribute master window |
| /slmreinitialize | *WARNING* This will wipe the database and start fresh |
| /slmquit | Exit the script |

## Pictures

![The main window, always shown](/images/gui_main.png)

![The config window and rules tab, optionally shown](/images/gui_config.rules.png)

![The rules table can be searched](/images/gui_config.rules.filter.png)

![The config button will change to red to show that there are unhandled rules that need your attention](/images/gui_main.unhandled.png)

![The config window will also change the Unhandled Rules tab to red when there are unhandled rules](/images/gui_config.rules.unhandled.png)

![A list of unhandled rules](/images/gui_config.unhandled.png)