#
# Returns a 2D array of distributions. The ij-th element is for the
# j-th element of the i-th particle from the previous population
#
function generate_kernels(
        population::AbstractArray{F,2},
        priors::AbstractArray{D,1},
        ) where {
        F<:AbstractFloat,
        D<:ContinuousUnivariateDistribution,
        }
    n_particles = size(population, 1)
    n_params = size(population, 2)

    stds = std(population, 1)[:]
    lowers = minimum.(priors)
    uppers = maximum.(priors)

    CUD = ContinuousUnivariateDistribution
    kernels = Matrix{CUD}(n_particles, n_params)
    for j in 1:n_params
        means = population[:, j]
        kernels[:, j] = TruncatedNormal.(means, stds[j]*sqrt(2), lowers[j], uppers[j])
    end

    return kernels
end


function generate_parameters(
        batch_size::Int64,
        priors::AbstractArray{D1,1},
        old_weights::StatsBase.Weights,
        kernels::AbstractArray{D2,2},
        ) where {
        D1, D2<:ContinuousUnivariateDistribution
        }

    n_params = length(priors)

    # ADD DimensionMismatch THROWS SO @inbounds CAN BE USED?

    # the kernels must be centered around the old particles
    # and truncated to the priors.

    particles = StatsBase.sample(indices(kernels, 1), old_weights, batch_size)
    # println("particle: $particles")
    perturbed_parameters = rand.(kernels[particles,:])
    # println("perturbed_parameters = $perturbed_parameters")

    # gives a batch_size x n_params matrix of prior pdfs in perturbed parameters
    pdfs = pdf.(reshape(priors, 1, n_params), perturbed_parameters)
    numerators = prod(pdfs, 2) # multiply across rows, to get a column vector of products of size batch_size

    denominators = zeros(length(numerators), 1)
    for k in eachindex(denominators)
        denominator_pdfs = pdf.(kernels, reshape(perturbed_parameters[k, :], 1, n_params))
        denominator_summands = prod(denominator_pdfs, 2)
        denominators[k] = sum(old_weights .* denominator_summands)
    end

    weight = numerators ./ denominators

    return perturbed_parameters, weight
end

# function generate_parameters_no_weights(
#         n_batch_size::Int64,
#         old_parameters::AbstractArray{F,2},
#         old_weights::StatsBase.Weights,
#         kernels::AbstractArray{D2,2}
#         ) where {
#         D2<:ContinuousUnivariateDistribution,
#         F<:AbstractFloat,
#         }
#     particles = StatsBase.sample(indices(old_parameters, 1), old_weights, n_batch_size)
#     return rand.(kernels[particles,:])
# end

function normalise(
        weights::StatsBase.AbstractWeights;
        tosum = 1.0,
        )
    WeightType = typeof(weights)
    weights = WeightType(weights.values .* (tosum / sum(weights.values)), tosum)

    return weights
end

function normalise(weight_values::AbstractArray{F, 1}, tosum = 1.0) where F<:AbstractFloat
    return StatsBase.Weights(weight_values .* (sum(weight_values) / tosum), tosum)
end

#
# Initialise a simulated ABC-SMC run
#
function initialiseABCSMC(input::SimulatedABCSMCInput,
        reference_data;
        out_stream::IO =  STDOUT,
        write_progress = true,
        progress_every = 1000,
        )
    # construct summary statistic function to be used in all runs
    built_summary_statistic = build_summary_statistic(input.summary_statistic)

    # the first run is an ABC rejection simulation
    rejection_input = SimulatedABCRejectionInput(input.n_params,
                                        input.n_particles,
                                        input.threshold_schedule[1],
                                        input.priors,
                                        built_summary_statistic,
                                        input.distance_function,
                                        input.simulator_function,
                                        input.max_iter,
                                        )

    rejection_output = ABCrejection(rejection_input,
                                    reference_data;
                                    out_stream = out_stream,
                                    write_progress = write_progress,
                                    progress_every = progress_every,
                                    )

    tracker =  SimulatedABCSMCTracker(input.n_params,
                             [rejection_output.n_accepted],
                             [rejection_output.n_tries],
                             [rejection_output.threshold],
                             [rejection_output.population],
                             [rejection_output.distances],
                             [rejection_output.weights],
                             input.priors,
                             built_summary_statistic,
                             input.distance_function,
                             input.simulator_function,
                             input.max_iter,
                             )

    return tracker
end

#
# Initialise an emulated ABC-SMC run
#
function initialiseABCSMC(input::EmulatedABCSMCInput,
        reference_data;
        out_stream::IO =  STDOUT,
        write_progress = true)
    # the first run is an ABC rejection simulation
    rejection_input = EmulatedABCRejectionInput(input.n_params,
                                        input.n_particles,
                                        input.threshold_schedule[1],
                                        input.priors,
                                        input.emulation_settings,
                                        input.batch_size,
                                        input.max_iter)

    rejection_output = ABCrejection(rejection_input,
                                    reference_data;
                                    out_stream = out_stream,
                                    write_progress = write_progress)

    tracker =  EmulatedABCSMCTracker(input.n_params,
                             [rejection_output.n_accepted],
                             [rejection_output.n_tries],
                             [rejection_output.threshold],
                             [rejection_output.population],
                             [rejection_output.distances],
                             [rejection_output.weights],
                             input.priors,
                             input.emulation_settings,
                             input.batch_size,
                             input.max_iter,
                             [rejection_output.emulator] # emulators
                             )

    return tracker
end

#
# Iterate a simulated ABC-SMC
#
function iterateABCSMC!(tracker::SimulatedABCSMCTracker,
        threshold::AbstractFloat,
        n_toaccept::Integer,
        reference_data;
        out_stream::IO = STDOUT,
        write_progress = true,
        progress_every = 1000,
        )
    if write_progress
        write(out_stream, string(DateTime(now())), " ABCSMC Simulation ϵ = $threshold.\n")
    end
    if threshold > tracker.threshold_schedule[end]
        println("Warning: current threshold less strict than previous one.")
    end
    kernels = generate_kernels(tracker.population[end], tracker.priors)
    reference_data_sum_stat = tracker.summary_statistic(reference_data)
    n_tries = 0
    n_accepted = 0
    population = zeros(n_toaccept, tracker.n_params)
    distances = zeros(n_toaccept)
    weights = zeros(n_toaccept)

    # simulate
    while n_accepted < n_toaccept && n_tries < tracker.max_iter
        parameters, weight = generate_parameters(1, tracker.priors, tracker.weights[end], kernels)
        parameters = parameters[1, :]
        weight = weight[1]
        simulated_data = tracker.simulator_function(parameters)
        simulated_data_sum_stat = tracker.summary_statistic(simulated_data)
        distance = tracker.distance_function(reference_data_sum_stat, simulated_data_sum_stat)
        n_tries += 1

        if distance <= threshold
            n_accepted += 1
            population[n_accepted,:] = parameters
            distances[n_accepted] = distance
            weights[n_accepted] = weight
        end

        if write_progress && (n_tries % progress_every == 0)
            write(out_stream, string(DateTime(now())),
                              " ABCSMC Simulation accepted ",
                              string(n_accepted),
                              "/",
                              string(n_tries),
                              " particles.\n"
                              )
            flush(out_stream)
        end
    end

    if n_accepted == 0
        warn("Simulation reached maximum $(tracker.max_iter) iterations without selecting any particles")
        return false
    end

    if n_accepted < n_toaccept
        population = population[1:n_accepted, :]
        weights = weights[1:n_accepted]
        distances = distances[1:n_accepted]
        warn("Simulation reached maximum $(tracker.max_iter) iterations before finding $(n_toaccept) particles - will return $n_accepted")
    else
        write(out_stream, string(DateTime(now())), " ABCSMC Simulation end. Accepted $(n_accepted)/$(n_toaccept)\n")
    end
    push!(tracker.n_accepted, n_accepted)
    push!(tracker.n_tries, n_tries)
    push!(tracker.threshold_schedule, threshold)
    push!(tracker.population, population)
    push!(tracker.distances, distances)
    push!(tracker.weights, normalise(weights))

    return true
end

#
# Iterate a emulated ABC-SMC
#
function iterateABCSMC!(tracker::EmulatedABCSMCTracker,
        threshold::AbstractFloat,
        n_toaccept::Integer,
        reference_data;
        out_stream::IO = STDOUT,
        write_progress = true,
        progress_every = 1000,
        )
    if write_progress
        write(out_stream, string(DateTime(now())), " ABCSMC Emulation ϵ = $threshold.\n")
    end

    old_population = tracker.population[end]
    old_weights = tracker.weights[end]

    if threshold > tracker.threshold_schedule[end]
        println("Warning: current threshold less strict than previous one.")
    end

    kernels = generate_kernels(old_population, tracker.priors)
    # prior_sampling_function(n_design_points) = generate_parameters_no_weights(n_design_points,
    #     old_population,
    #     old_weights,
    #     kernels)
    prior_sampling_function = function(n_design_points)
        ret_idx = StatsBase.sample(indices(old_population, 1), old_weights, n_design_points)
        return old_population[ret_idx, :]
    end
    emulator = tracker.emulation_settings.train_emulator_function(prior_sampling_function)

    # initialise
    iter_no = 0
    n_accepted = 0
    all_weights = zeros(n_toaccept)
    population = zeros(n_toaccept, tracker.n_params)
    all_distances = zeros(n_toaccept)
    n_tries = 0

    # emulate
    while n_accepted < n_toaccept && iter_no < tracker.max_iter
        parameters, weights = generate_parameters(tracker.batch_size,
                                                 tracker.priors,
                                                 old_weights,
                                                 kernels)

        distances, vars = tracker.emulation_settings.emulate_distance_function(parameters, emulator)
        n_tries += length(distances)
        accepted_indices = find((distances .<= threshold) .& (sqrt.(vars) .<= threshold)) # todo more variance controls
        # accepted_indices = find(distances .<= threshold)
        n_include = length(accepted_indices)
        if n_accepted + n_include > n_toaccept
            n_include = n_toaccept - n_accepted
            accepted_indices = accepted_indices[1:n_include]
        end
        distances = distances[accepted_indices]
        weights = weights[accepted_indices]
        parameters = parameters[accepted_indices, :]
        store_slice = n_accepted + 1 : n_accepted + n_include
        n_accepted += n_include
        population[store_slice,:] = parameters
        all_distances[store_slice] = distances
        all_weights[store_slice] = weights

        if write_progress
            write(out_stream, string(DateTime(now())),
                              " ABCSMC Emulation accepted ",
                              string(n_accepted),
                              "/",
                              string(n_tries),
                              " particles.\n"
                              )
            flush(out_stream)
        end

        iter_no += 1
    end

    if n_accepted == 0
        warn("Emulation reached maximum $(tracker.max_iter) iterations without selecting any particles")
        return false
    end

    if n_accepted < n_toaccept
        population = population[1:n_accepted, :]
        all_weights = all_weights[1:n_accepted]
        all_distances = all_distances[1:n_accepted]
        warn("Emulation reached maximum $(tracker.max_iter) iterations before finding $(n_toaccept) particles - will return $n_accepted")
    end
    push!(tracker.n_accepted, n_accepted)
    push!(tracker.n_tries, n_tries)
    push!(tracker.threshold_schedule, threshold)
    push!(tracker.population, population)
    push!(tracker.distances, all_distances)
    push!(tracker.weights, normalise(all_weights))
    push!(tracker.emulators, emulator)

    return true
end

function buildAbcSmcOutput(input::EmulatedABCSMCInput, tracker::EmulatedABCSMCTracker)
    EmulatedABCSMCOutput(input.n_params,
                        tracker.n_accepted,
                        tracker.n_tries,
                        tracker.threshold_schedule,
                        tracker.population,
                        tracker.distances,
                        tracker.weights,
                        tracker.emulators)
end

function buildAbcSmcOutput(input::SimulatedABCSMCInput, tracker::SimulatedABCSMCTracker)
    SimulatedABCSMCOutput(input.n_params,
                        tracker.n_accepted,
                        tracker.n_tries,
                        tracker.threshold_schedule,
                        tracker.population,
                        tracker.distances,
                        tracker.weights)
end

"""
  ABCSMC

Run a ABC-SMC computation using either simulation (the model is simulated in full for each parameter vector from which the corresponding
distance to observed data is used to construct the posterior) or emulation (a regression model trained to predict the distance from the
parameter vector directly is used to construct the posterior). Whether simulation or emulation is used is controlled by the type of `input`.

# Fields
- `input::ABCSMCInput`: An ['SimulatedABCSMCInput'](@ref) or ['EmulatedABCSMCInput'](@ref) object that defines the settings for thw ABC-SMC run.
- `reference_data::AbstractArray{Float64,2}`: The observed data to which the simulated model output will be compared. Size: (n_model_trajectories, n_time_points)
- `out_stream::IO`: The output stream to which progress will be written. An optional argument whose default is `STDOUT`.
- `write_progress::Bool`: Optional argument controlling whether progress is written to `out_stream`.
- `progress_every::Int`: Progress will be written to `out_stream` every `progress_every` simulations (optional, ignored if `write_progress` is `False`).
"""
function ABCSMC(
        input::ABCSMCInput,
        reference_data::AbstractArray{Float64,2};
        out_stream::IO = STDOUT,
        write_progress = true,
        progress_every = 1000,
        )
    n_toaccept = input.n_particles

    tracker = initialiseABCSMC(input,
                               reference_data;
                               out_stream = out_stream,
                               write_progress = write_progress)

    if tracker.n_accepted[1] > 0
        for i in 2:length(input.threshold_schedule)
            # @assert size(tracker.population[end], 1) > 0 "No particles were accepted by step #$(i-1) of ABC SMC"
            threshold = input.threshold_schedule[i]
            complete_threshold = iterateABCSMC!(tracker,
                           threshold,
                           input.n_particles,
                           reference_data;
                           out_stream = out_stream,
                           write_progress = write_progress,
                           progress_every = progress_every,
                           )
            if !complete_threshold
                break
            end
        end
    else
        warn("No particles selected at initial rejection ABC step of SMC ABC")
    end

    return buildAbcSmcOutput(input, tracker)
end