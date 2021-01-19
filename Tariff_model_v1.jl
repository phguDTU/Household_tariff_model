using CSV, DataFrames
using JuMP, Gurobi, CPLEX
import XLSX

Sets = CSV.read("Data/Sets.csv", DataFrame)
#Sets = Dict( string(i) => collect(skipmissing(Sets[:,i])) for i in names(Sets))

Demand_profiles = CSV.read("Data/Demand_profiles.csv", DataFrame)

El_price = CSV.read("Data/Electricity_prices.csv", DataFrame)
Network_tariffs  = CSV.File("Data/Network_tariffs.csv") |> Dict

PV_par = CSV.File("Data/PV_par.csv") |> Dict
Battery_par = CSV.File("Data/Battery_par.csv") |> Dict
Grid_par = CSV.File("Data/Grid_par.csv") |> Dict
Scalars = CSV.File("Data/Scalars.csv") |> Dict

PV_CF = CSV.read("Data/SolarCF.csv", DataFrame)[:,"SolarCF"]

# SETS
T = Sets[:,"T"]
Y = [1]
# SELECTING THE TYPE OF DEMAND

Demand_Type = "T1"

# Fixing the demand for a specific year
Demand = Array{Float64}(undef, length(T), length(Y))
Demand[:,:] .= Demand_profiles[:,Demand_Type]

M = Model(CPLEX.Optimizer)

# Battery related variables
@variable(M, C_BT, lower_bound=0, base_name="Capacity of battery [kWh]")
@variable(M, b_st[T in T, y in Y], lower_bound=0, base_name="Battery status in hour T")
@variable(M, b_dh[T in T, y in Y], lower_bound=0, base_name="Battery discharging in hour T")
@variable(M, b_dh_load[T in T, y in Y], lower_bound=0, base_name="Battery discharging to the load in hour T")
@variable(M, b_dh_ex[T in T, y in Y], lower_bound=0, base_name="Battery discharging to the grid in hour T")
@variable(M, b_ch[T in T, y in Y], lower_bound=0, base_name="Battery charging in hour T")

# PV related constraints
@variable(M, C_PV, lower_bound=0, base_name="Capacity of PV array [kW]")
@variable(M, p_PV[T in T, y in Y], lower_bound=0, base_name="Production level of PV array [kW]")
@variable(M, p_PV_load[T in T, y in Y], lower_bound=0, base_name="Production of PV array used directly to satisfy the load [kW]")
@variable(M, p_PV_bat[T in T, y in Y], lower_bound=0, base_name="Production level of PV array used to charge the battery [kW]")
@variable(M, p_PV_ex[T in T, y in Y], lower_bound=0, base_name="Production level of PV array exported to the grid[kW]")

# Grid related constraints
@variable(M, g_ex[T in T, y in Y], lower_bound=0, base_name="Export to the grid in hour T")
@variable(M, g_im[T in T, y in Y], lower_bound=0, base_name="Import from the grid in hour T")
@variable(M, g_im_load[T in T, y in Y], lower_bound=0, base_name="Import from the grid to satisfy the load in hour T")
@variable(M, g_im_bat[T in T, y in Y], lower_bound=0, base_name="Import from the grid to charge the battery in hour T")

# Fixing the capacity variables
fix(C_PV, 100; force=true);
fix(C_BT, 20; force=true);


# Define the objective function

    @objective(M, Min, sum(Scalars["CRF"]*PV_par["Capital_cost"]*C_PV + Scalars["CRF"]*Battery_par["Capital_cost"]*C_BT for y in Y) +
    Battery_par["OP_cost"]*sum(b_dh[t,y] + b_ch[t,y] for t in T for y in Y) + sum(g_im[t,y]*(El_price[t,"Tariff_import"]+Network_tariffs["Var_dist"]+Network_tariffs["PSO"]) - g_ex[t,y]*(El_price[t,"Tariff_export"]+Network_tariffs["Var_dist"]) for t in T for y in Y)
    + sum(Network_tariffs["Fixed_dist"] for y in Y))
    + sum(g_im_load[t,y] + p_PV_load[t,y] + g_im_bat[t,y] + p_PV_bat[t,y] - b_dh_ex[t,y] for t in T for y in Y)

# Balancing constraint taking into account only load flows
@constraint(M, Balance[t in T, y in Y], g_im_load[t,y] + b_dh_load[t,y] + p_PV_load[t,y] - Demand[t,y] == 0)

# SOC regular balance when the hours set is not 1
@constraint(M, SOC[t in T, y in Y; t>1], b_st[t,y] == b_st[t-1,y] - b_dh[t,y]/Battery_par["Discharging_eff"] + b_ch[t,y]*Battery_par["Charging_eff"])

# SOC balance for the first hour and NOT first year
@constraint(M, SOC_LastT[t in T, y in Y; t == 1 && y!=1], b_st[t,y] == b_st[last(T),y-1] - b_dh[t,y]/Battery_par["Discharging_eff"] + b_ch[t,y]*Battery_par["Charging_eff"])

# SOC balance for the first hour and first year
@constraint(M, SOC_First[t in T, y in Y; t==1 && y==1], b_st[t,y] == C_BT - b_dh[t,y]/Battery_par["Discharging_eff"] + b_ch[t,y]*Battery_par["Charging_eff"] )

# Limit on the maximum charge state of charge of the battery
@constraint(M, SOC_lim_up[t in T, y in Y], b_st[t,y] <= Battery_par["Max_charge"]*C_BT)

# Limit on the maximum hourly charging
@constraint(M, Charge_limit[t in T, y in Y], b_ch[t,y] <= Battery_par["Charging_lim"]*C_BT)

# Limit on the maximum hourly discharging
@constraint(M, Discharge_limit[t in T, y in Y], b_ch[t,y] <= Battery_par["Discharging_lim"]*C_BT)

# Limit on the minimum battery state of charge (depth of discharge)
@constraint(M, SOC_lim_down[t in T, y in Y], b_st[t,y] >= (1-Battery_par["Depth_of_discharge"])*C_BT)

# Limit on the amount of hourly exported electricity
@constraint(M, grid_ex_lim[t in T, y in Y], g_ex[t,y] <= Grid_par["Ex_lim"])

# Limit on the amount of hourly imported electricity
@constraint(M, grid_im_lim[t in T, y in Y], g_im[t,y] <= Grid_par["Im_lim"])

# Balance of the imported energy
@constraint(M, grid_im_def[t in T, y in Y], g_im[t,y] == g_im_load[t,y] + g_im_bat[t,y])

# Balance of the exported energy
@constraint(M, grid_ex_def[t in T, y in Y], g_ex[t,y] == p_PV_ex[t,y] + b_dh_ex[t,y])

# Balance of the charging energy
@constraint(M, bat_ch_def[t in T, y in Y], b_ch[t,y] == p_PV_bat[t,y] + g_im_bat[t,y])

# Balance of the discharging energy
@constraint(M, bat_dh_def[t in T, y in Y], b_dh[t,y] == b_dh_ex[t,y] + b_dh_load[t,y])

# Balance of the PV energy
@constraint(M, PV_prod_def[t in T, y in Y], C_PV*PV_CF[t,y] == p_PV_bat[t,y] + p_PV_ex[t,y] + p_PV_load[t,y])
# ---------------------------------
# SOLVING COMMANDS
optimize!(M)

println( "----------- OBJECTIVE FUNCTION ------------")
println( "OF: ",round(objective_value(M)),"\n")
println( "\n")

# Function to convert variables to the data_frames
function ExportVariable(variable, sets, sets_names)
    # Create column names of the dataframe
    colnames= Symbol.(var for var in push!(sets_names, "Value"))

    # Create dataframe
    df = DataFrame(fill(Any, length(colnames)), colnames)

    for i1 in sets[1]
        if length(sets) == 1
            push!(df, Tuple([i1, value(variable[i1,i2])]))
        else
            for i2 in sets[2]
                if length(sets) == 2
                    push!(df, Tuple([i1, i2, value(variable[i1,i2])]))
                else
                    for i3 in sets[3]
                        if length(sets) == 2
                            push!(df, Tuple([i1, i2,i3, value(variable[i1,i2,i3])]))
                        end
                    end
                end
            end
        end
    end
    return df
end

# List of all variables (not in use now)
VARS = [b_st,b_dh,b_dh_load,b_dh_ex,b_ch,p_PV,p_PV_load,p_PV_bat,p_PV_ex,g_ex,g_im,g_im_load,g_im_bat]

# If Results.xlsx exists then remove
if isfile("Results.xlsx")
    rm("Results.xlsx")
end

# Writing results to excel
    XLSX.writetable("Results.xlsx",
                                b_st=( collect(DataFrames.eachcol(ExportVariable(b_st,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(b_st,[T,Y],["T","Y"]))),

                                b_dh=( collect(DataFrames.eachcol(ExportVariable(b_dh,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(b_dh,[T,Y],["T","Y"]))),

                                b_dh_load=( collect(DataFrames.eachcol(ExportVariable(b_dh_load,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(b_dh_load,[T,Y],["T","Y"]))),

                                b_dh_ex=( collect(DataFrames.eachcol(ExportVariable(b_dh_ex,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(b_dh_ex,[T,Y],["T","Y"]))),

                                b_ch=( collect(DataFrames.eachcol(ExportVariable(b_ch,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(b_ch,[T,Y],["T","Y"]))),

                                p_PV=( collect(DataFrames.eachcol(ExportVariable(p_PV,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(p_PV,[T,Y],["T","Y"]))),

                                p_PV_load=( collect(DataFrames.eachcol(ExportVariable(p_PV_load,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(p_PV_load,[T,Y],["T","Y"]))),

                                p_PV_bat=( collect(DataFrames.eachcol(ExportVariable(p_PV_bat,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(p_PV_bat,[T,Y],["T","Y"]))),

                                g_ex=( collect(DataFrames.eachcol(ExportVariable(g_ex,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(g_ex,[T,Y],["T","Y"]))),

                                g_im=( collect(DataFrames.eachcol(ExportVariable(g_im,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(g_im,[T,Y],["T","Y"]))),

                                g_im_load=( collect(DataFrames.eachcol(ExportVariable(g_im_load,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(g_im_load,[T,Y],["T","Y"]))),

                                g_im_bat=( collect(DataFrames.eachcol(ExportVariable(g_im_bat,[T,Y],["T","Y"]))), DataFrames.names(ExportVariable(g_im_bat,[T,Y],["T","Y"]))),
                                )
