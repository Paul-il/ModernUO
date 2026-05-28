-- team_supporter.lua: Gather resources and signal the team
-- Demonstrates: signals, inventory checks, conditional harvesting
bot.state.trips = bot.state.trips or 0

function main()
    bot.log("Team supporter script started")

    while true do
        -- Check what resources the team needs
        local ingots = bot.count_ingots()
        local logs = bot.count_logs()

        if ingots < 20 then
            bot.say("Mining for the team")
            bot.walk_to("mine")
            bot.mine_until(function()
                return bot.count_ore() >= 40 or bot.is_overweight()
            end)
            bot.walk_to("forge")
            bot.smelt_all()
            bot.signal("resources_ready", "ingots")
        end

        if logs < 20 then
            bot.say("Chopping wood")
            bot.walk_to("trees")
            bot.chop_until(function()
                return bot.count_logs() >= 40 or bot.is_overweight()
            end)
            bot.signal("resources_ready", "logs")
        end

        -- If overweight, request runner pickup
        if bot.is_overweight() then
            bot.request_runner("PickupResources")
            wait(10)
        end

        bot.state.trips = bot.state.trips + 1
        if bot.state.trips % 5 == 0 then
            bot.log("Completed " .. bot.state.trips .. " gather trips")
        end

        yield()
    end
end
