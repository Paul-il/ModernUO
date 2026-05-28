-- miner.lua: Simple mining bot script
-- Demonstrates: walk_to, mine_until, smelt_all, yield
bot.state.ore_mined = bot.state.ore_mined or 0

function main()
    bot.log("Miner script started")

    while true do
        -- Walk to mine
        bot.walk_to("mine")

        -- Mine until we have enough ore or are overweight
        bot.mine_until(function()
            return bot.count_ore() >= 30 or bot.is_overweight()
        end)

        bot.state.ore_mined = bot.state.ore_mined + bot.count_ore()
        bot.log("Mined " .. bot.count_ore() .. " ore (total: " .. bot.state.ore_mined .. ")")

        -- Walk to forge and smelt
        bot.walk_to("forge")
        bot.smelt_all()

        bot.say("Smelted ore, now have " .. bot.count_ingots() .. " ingots")
        yield()
    end
end
