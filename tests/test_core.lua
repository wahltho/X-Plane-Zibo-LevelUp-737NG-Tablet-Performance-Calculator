local core = dofile("B738.tablet_perf_core.lua")

local function assert_near(actual, expected, tolerance, label)
    if math.abs(actual - expected) > tolerance then
        error(string.format("%s: expected %.9f, got %.9f", label, expected, actual))
    end
end

local function representative(variant, weight, flaps)
    return {
        variant = variant,
        runway_length_m = 3000,
        runway_slope_percent = 0,
        headwind_kt = 0,
        dry = true,
        oat_c = 15,
        pressure_altitude_ft = 0,
        takeoff_weight_t = weight,
        flaps = flaps or 5,
        option_1 = true,
        option_2 = false,
        option_3 = false,
        requested_rating = core.full_thrust_rating(variant),
        requested_assumed_temp_c = 0,
        cg_percent = 25,
    }
end

assert(core.variant_from_aircraft_id(-1) == 0)
assert(core.variant_from_aircraft_id(0) == 3)
assert(core.variant_from_aircraft_id(1) == 4)
assert(core.variant_from_aircraft_id(2) == 2)
assert(core.variant_from_aircraft_id(3) == 1)
assert(core.variant_from_aircraft_id(4) == 5)
assert(table.concat(core.rating_family(0), ",") == "26,24,22")
assert(table.concat(core.rating_family(2), ",") == "24,22,20")
assert(table.concat(core.rating_family(5), ",") == "27,24,22")

local coverage = {
    {0, 58}, {1, 45}, {2, 50}, {3, 60}, {4, 60}, {5, 65},
}
for _, item in ipairs(coverage) do
    for _, dry in ipairs({true, false}) do
        for _, altitude in ipairs({0, 4000}) do
            for _, flaps in ipairs({1, 5, 10, 15, 25}) do
                local input = representative(item[1], item[2], flaps)
                input.dry = dry
                input.pressure_altitude_ft = altitude
                local result = core.calculate_takeoff(input)
                assert(result.full.valid, string.format("takeoff coverage variant=%d dry=%s alt=%d flaps=%d", item[1], tostring(dry), altitude, flaps))
                assert(result.assumed.valid)
                assert(result.selected_flaps == flaps)
                assert(result.full.v1 <= result.full.vr and result.full.vr <= result.full.v2)
                assert(result.stabilizer_trim >= 0)
            end
        end
    end
end

for _, rating in ipairs({24, 22, 20}) do
    for _, dry in ipairs({true, false}) do
        for _, altitude in ipairs({0, 4000}) do
            for _, flaps in ipairs({1, 5, 10, 15, 25}) do
                local input = representative(2, 50, flaps)
                input.requested_rating = rating
                input.dry = dry
                input.pressure_altitude_ft = altitude
                local levelup700 = core.calculate_takeoff(input)
                assert(levelup700.full.valid, string.format(
                    "737-700 rating coverage rating=%d dry=%s alt=%d flaps=%d",
                    rating, tostring(dry), altitude, flaps))
                assert(levelup700.full.rating == rating)
            end
        end
    end
    local input = representative(2, 56, 5)
    input.runway_length_m = 3600
    input.oat_c = 28
    input.pressure_altitude_ft = -167
    input.requested_rating = rating
    local levelup700 = core.calculate_takeoff(input)
    assert(levelup700.full.valid, "737-700 EDDB low-pressure-altitude rating " .. rating)
    assert(levelup700.full.rating == rating)
end

local derate_weights = { [24] = 65, [22] = 60 }
for _, rating in ipairs({24, 22}) do
    for _, dry in ipairs({true, false}) do
        for _, altitude in ipairs({0, 4000}) do
            for _, flaps in ipairs({1, 5, 10, 15, 25}) do
                local input = representative(5, derate_weights[rating], flaps)
                input.requested_rating = rating
                input.dry = dry
                input.pressure_altitude_ft = altitude
                local derated = core.calculate_takeoff(input)
                assert(derated.full.valid, string.format(
                    "900ER derate coverage rating=%d dry=%s alt=%d flaps=%d",
                    rating, tostring(dry), altitude, flaps))
                assert(derated.full.rating == rating)
                if derated.assumed.valid then assert(derated.assumed.rating == rating) end
                assert(derated.stabilizer_trim >= 0)
            end
        end
    end
end

local essb = representative(0, 54.4, 5)
essb.runway_length_m = 1895
essb.runway_slope_percent = ((47 - 43) * 0.3048 / 1895) * 100
essb.oat_c = 18
essb.pressure_altitude_ft = 43 + (1013 - 1002) * 27
essb.requested_rating = 0
essb.cg_percent = 20.9
local result = core.calculate_takeoff(essb)
assert(result.full.valid and result.assumed.valid)
assert_near(result.maximum_takeoff_weight_t, 67.861173, 0.001, "ESSB max weight")
assert(result.selected_flaps == 5)
assert(result.full.rating == 22)
assert_near(result.full.n1_percent, 92.2444, 0.01, "ESSB full N1")
assert(result.full.v1 == 125 and result.full.vr == 125 and result.full.v2 == 135)
assert(result.assumed.rating == 22 and result.assumed.temperature_c == 40)
assert_near(result.assumed.n1_percent, 88.954, 0.01, "ESSB ATM N1")
assert(result.assumed.v1 == 127 and result.assumed.vr == 127 and result.assumed.v2 == 134)
assert_near(result.stabilizer_trim, 5.4506, 0.001, "ESSB trim")
assert(result.vref40 == 127)

local landing_input = {
    variant = 3,
    flaps = 30,
    condition = 0,
    landing_weight_kg = 65000,
    pressure_altitude_ft = 0,
    headwind_kt = 0,
    runway_slope_percent = 0,
    oat_c = 15,
    vref_add_kt = 0,
    reversers = 0,
    manual_speedbrakes = false,
}
local landing = assert(core.calculate_landing(landing_input))
assert_near(landing.distances[0], 960, 0.001, "landing max manual")
assert_near(landing.distances[4], 1215, 0.001, "landing max auto")
assert_near(landing.distances[3], 1725, 0.001, "landing autobrake 3")
assert_near(landing.distances[2], 2190, 0.001, "landing autobrake 2")
assert_near(landing.distances[1], 2415, 0.001, "landing autobrake 1")

for variant = 1, 5 do
    for _, flaps in ipairs({15, 30, 40}) do
        for condition = 0, 3 do
            landing_input.variant = variant
            landing_input.flaps = flaps
            landing_input.condition = condition
            local matrix = assert(core.calculate_landing(landing_input))
            for brake = 0, 4 do
                assert(matrix.distances[brake] >= matrix.air_distance_m)
            end
        end
    end
end

print("PASS: Lua performance core")
