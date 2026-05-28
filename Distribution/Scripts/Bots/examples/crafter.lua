-- crafter.lua: Full weapon crafting cycle
-- Demonstrates: mining, smelting, crafting, tool check, wait
bot.state.craft_count = bot.state.craft_count or 0

function main()
    bot.log("Weapon crafter script started")

    while true do
        -- Ensure we have a pickaxe
        if not bot.has_pickaxe() then
            bot.walk_to("forge")
            bot.craft("tinkering", "pickaxe")
        end

        -- Mine if low on ingots
        if bot.count_ingots() < 10 then
            bot.walk_to("mine")
            bot.mine_until(function()
                return bot.count_ore() >= 30 or bot.is_overweight()
            end)
            bot.walk_to("forge")
            bot.smelt_all()
        end

        -- Craft weapons at forge
        bot.walk_to("forge")
        while bot.count_ingots() >= 10 do
            bot.craft("blacksmith", "katana")
            bot.state.craft_count = bot.state.craft_count + 1
            if bot.state.craft_count % 10 == 0 then
                bot.say("Crafted " .. bot.state.craft_count .. " weapons")
            end
            yield()
        end

        yield()
    end
end
