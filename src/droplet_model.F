!
! NOTE: This module was generated from sneaky-slushy on 2026/10/14 at 09:11:06.
!       Do not modify this directly!  Update the module generator's template and
!       regenerate this file!
!

module droplet_model

    ! Module containing a model of droplet size and temperature using a 4-layer
    ! multi-layer perceptron (MLP) neural network.  Once initialized, a single
    ! droplet's parameters and timestep can be used to estimate its future size
    ! and temperature.  This approach avoids an iterative search using
    ! Gauss-Newton to estimate its future charueacteristics and is typically much
    ! faster (O(30x) observed for small parameter count MLPs).
    !
    ! The module must be initialized with a call to initialize_model() and then
    ! droplet estimation, estimate(), can be performed as many times as
    ! necessary.  Weights for the MLP are hardcoded so initialization does not
    ! require any external resources.  An example calling sequence is the
    ! following:
    !
    !     ! Somewhere during simulation startup.
    !     call initialize_model()
    !
    !     ...
    !
    !     ! Particle simulation code.
    !     real*4 :: input_parameters(NUMBER_INPUTS)
    !     real*4 :: output_parameters(NUMBER_OUTPUTS)
    !
    !     do particle_index = 1, number_particles
    !
    !         input_parameters = [radius, temperature, salt_solute, air_temperature, rh, rhoa, t_final]
    !         call estimate( input_parameters, output_parameters )
    !
    !         new_radius      = output_parameters(RADIUS_INDEX)
    !         new_temperature = output_parameters(TEMPERATURE_INDEX)
    !
    !     end do
    !
    ! Inputs to the estimation, as are outputs, are provided in physical units
    ! and are internally normalized before using the model allowing this to be a
    ! drop-in replacement for alternative approaches for estimating droplet
    ! characteristics.
    !
    ! The model was trained on droplet parameters sampled from the product space
    ! of each of the individual parameters.  While this simple approach allowed
    ! for rapid development of a prototype it does include combinations of
    ! parameters that may be physically impossible which may have been
    ! under-sampled during training.  As a result the estimations in these
    ! corners of the parameter space may be of lower accuracy than more sampled,
    ! better behaved regions of the space.  The initial parameter ranges were
    ! selected by David Richter during prototyping and aim to cover all
    ! simulations of interest.
    !
    ! Things to note:
    !
    !   1. This approach was developed for code that would operate on a single
    !      droplet at a time vs multiple droplets at once.  As a result the
    !      application of a MLP network is simply a series of matrix-vector
    !      multiplications, vector-vector additions, and an activation function
    !      applied to the result.  We implement this case rather than attempt to
    !      generalize as the performance gain is already non-trivial and it is
    !      unclear when the code (if ever) would support batch estimation.
    !
    !   2. We could statically initialize each layer's weights and biases at
    !      compile time, albeit at the expense of readability.  By separating
    !      the weights and biases' definitions from their values we retain the
    !      ability to understand the structure and internal components of the
    !      MLP while requiring a single subroutine call at startup.
    !
    !   3. This is a naive implementation of a N-layer MLP (it was originally
    !      written in 15 minutes!)  and does not implement all potential
    !      optimizations.  In particular, each intermediate layer has its own
    !      array and no attempt to reuse arrays or work out of one large array
    !      has been made, so as to minimize the MLP's run-time footprint.  As
    !      initially developed the MLP was very small (O(2500) parameters) and
    !      used O(10 KiB) storage, though should this ever be used for much
    !      larger MLPs, or with larger batch sizes (see above) then some of the
    !      omitted optimizations should be revisited.
    !
    !   4. While the MLP was trained on the product space of the input
    !      parameters and has poor performance on certain (likely) physically
    !      impossible parameter combinations, it is unclear what need to be done
    !      to improve the situation.  Re-training on a subset of the input
    !      parameters might improve performance and could be done without
    !      changing this implementation (albeit with undefined behavior for any
    !      physically impossible input) but it remains to be seen how much
    !      accuracy would be gained from this.
    !
    !   5. This approach is *NOT* OpenMP safe and is inherently single-threaded!
    !      Should multiple estimations need to be performed in parallel, an
    !      additional interface is needed that provides the intermediate layers
    !      to the estimation subroutine.  All of the weights and biases are
    !      effectively read-only and can be shared across threads.  This is
    !      straight forward to implement though it was not necessary for the
    !      initial implementation.
    !
    !   6. Single precision floating point is used throughout the module as it
    !      has been deemed to produce an acceptable level of accuracy for the
    !      radius and temperature parameters.  The input and output arrays
    !      must be real*4.
    !
    ! NOTE: This file was automatically generated from the the MLP's training
    !       code!  Do not modify this unless you really know what you're doing!
    !

    ! Model metadata to help with debugging.
    !
    ! NOTE: This is restricted to 128 characters to avoid running afoul of modern
    !       Fortran's 132 character limit.  We start the actual string literal on
    !       its own line to avoid generating a compiler warning when we have a
    !       long string.
    !
    character(len=128), parameter :: model_metadata = &
 "sneaky-slushy (2026/10/14 at 09:11:06)"

    ! Indices into the input and output vectors.  The input vector uses all of
    ! the indices while the output vector only uses the first two.
    integer, parameter :: RADIUS_INDEX          = 1
    integer, parameter :: TEMPERATURE_INDEX     = 2
    integer, parameter :: SALT_SOLUTE_INDEX     = 3
    integer, parameter :: AIR_TEMPERATURE_INDEX = 4
    integer, parameter :: RH_INDEX              = 5
    integer, parameter :: RHOA_INDEX            = 6
    integer, parameter :: TFINAL_INDEX          = 7

    integer, parameter :: NUMBER_INPUTS  = 7
    integer, parameter :: NUMBER_OUTPUTS = 3

    integer, parameter :: NUMBER_HIDDEN_LAYER1_NEURONS = 32
    integer, parameter :: NUMBER_HIDDEN_LAYER2_NEURONS = 32
    integer, parameter :: NUMBER_HIDDEN_LAYER3_NEURONS = 32

    ! The input variables must be normalized into the range of [-1, 1] before
    ! feeding them into the model.  The following ranges, means, and widths are
    ! used to map into, and from, the range of [-1, 1].
    !
    ! NOTE: These *must* match the training data!  Do not change these without
    !       retraining the model!
    !
    real*4, parameter :: RADIUS_LOG_RANGE(2)      = [-8.000, -2.500]
    real*4, parameter :: TEMPERATURE_RANGE(2)     = [270.0, 310.0]
    real*4, parameter :: SALT_SOLUTE_LOG_RANGE(2) = [-22.00, -7.50]
    real*4, parameter :: AIR_TEMPERATURE_RANGE(2) = [270.00, 310.00]
    real*4, parameter :: RH_RANGE(2)              = [0.25, 1.25]
    real*4, parameter :: RHOA_RANGE(2)            = [0.80, 1.25]

    real*4, parameter :: RADIUS_LOG_MEAN      = SUM( RADIUS_LOG_RANGE ) / 2
    real*4, parameter :: TEMPERATURE_MEAN     = SUM( TEMPERATURE_RANGE ) / 2
    real*4, parameter :: SALT_SOLUTE_LOG_MEAN = SUM( SALT_SOLUTE_LOG_RANGE ) / 2
    real*4, parameter :: AIR_TEMPERATURE_MEAN = SUM( AIR_TEMPERATURE_RANGE ) / 2
    real*4, parameter :: RH_MEAN              = SUM( RH_RANGE ) / 2
    real*4, parameter :: RHOA_MEAN            = SUM( RHOA_RANGE ) / 2

    !
    ! NOTE: We have be careful about lines no longer than 132 characters so we
    !       eliminate whitespace in the expressions.
    !
    real*4, parameter :: RADIUS_LOG_WIDTH      = (RADIUS_LOG_RANGE(2)-RADIUS_LOG_RANGE(1))/2
    real*4, parameter :: TEMPERATURE_WIDTH     = (TEMPERATURE_RANGE(2)-TEMPERATURE_RANGE(1))/2
    real*4, parameter :: SALT_SOLUTE_LOG_WIDTH = (SALT_SOLUTE_LOG_RANGE(2)-SALT_SOLUTE_LOG_RANGE(1))/2
    real*4, parameter :: AIR_TEMPERATURE_WIDTH = (AIR_TEMPERATURE_RANGE(2)-AIR_TEMPERATURE_RANGE(1))/2
    real*4, parameter :: RH_WIDTH              = (RH_RANGE(2)-RH_RANGE(1))/2
    real*4, parameter :: RHOA_WIDTH            = (RHOA_RANGE(2)-RHOA_RANGE(1))/2

    ! The integration time is normalized linearly, unlike the radius and salt
    ! solute (which are normalized in log10).  The *range* is specified in
    ! log10( seconds ), matching physics.DROPLET_TIME_LOG_RANGE, since that is
    ! how dt is sampled when generating training data, but dt itself enters the
    ! network linearly: near the timesteps integrated here several of dydt()'s
    ! regimes have a dt-independent rate, so the radius/temperature change is
    ! proportional to dt rather than to its logarithm.
    !
    ! NOTE: TIME_RANGE is 10**TIME_LOG_RANGE, evaluated here as a literal since
    !       a real-valued exponentiation is not a constant expression in
    !       Fortran.  Keep the two in sync if the training range changes.
    !
    real*4, parameter :: TIME_LOG_RANGE(2) = [-2.500, -0.800]
    real*4, parameter :: TIME_RANGE(2)     = [3.1622777e-3, 1.5848932e-1]

    real*4, parameter :: TIME_MEAN  = SUM( TIME_RANGE ) / 2
    real*4, parameter :: TIME_WIDTH = (TIME_RANGE(2)-TIME_RANGE(1))/2

    ! ------------------------------------------------------------------------
    ! Analytic baseline and radius equilibrium.
    !
    ! The network does not regress the stepped radius/temperature directly.  It
    ! regresses a *correction* to a closed-form analytic baseline (see
    ! analytic_baseline_step(), below), and a third output neuron classifies
    ! whether the droplet is sitting at a radius equilibrium, in which case the
    ! physics-derived equilibrium is used in place of the regression entirely
    ! (see radius_equilibrium()).  Both mirror
    ! models.QuadraticResidualnet_scaled_layernorm_eq_classifier_analytic.
    !
    ! NOTE: These two routines are evaluated in double precision even though
    !       the network itself is single precision.  This is *not* optional:
    !       the baseline's log-difference term is O(1e-9) against operands of
    !       O(0.1) (single precision loses it entirely -- measured up to 16%
    !       error in the stepped radius), and the equilibrium cubic's
    !       discriminant reaches O(1e46), which overflows real*4 outright.
    ! ------------------------------------------------------------------------

    ! Physical constants, identical to those hard-coded in physics.dydt().
    real*8, parameter :: PHYS_SHP  = 2.0d0
    real*8, parameter :: PHYS_SC   = 0.615d0
    real*8, parameter :: PHYS_NUF  = 1.57d-5
    real*8, parameter :: PHYS_RHOW = 1000.0d0
    real*8, parameter :: PHYS_MW   = 0.018015d0
    real*8, parameter :: PHYS_RU   = 8.3144d0
    real*8, parameter :: PHYS_GAM  = 7.28d-2
    real*8, parameter :: PHYS_LV   = (25.0d0 - 0.02274d0*26.0d0)*1.0d5
    real*8, parameter :: PHYS_NUP  = 2.0d0
    real*8, parameter :: PHYS_PRA  = 0.715d0
    real*8, parameter :: PHYS_CPA  = 1006.0d0
    real*8, parameter :: PHYS_CPP  = 4179.0d0
    real*8, parameter :: PHYS_PI   = 3.141592653589793238d0

    ! Groupings of the above that are loop invariant.  These are constant
    ! expressions so they fold at compile time and cost nothing at run time.
    real*8, parameter :: LV_MW_RU      = PHYS_LV*PHYS_MW/PHYS_RU
    real*8, parameter :: MW_RU         = PHYS_MW/PHYS_RU
    real*8, parameter :: KELVIN_COEFF  = 2.0d0*PHYS_MW*PHYS_GAM/(PHYS_RU*PHYS_RHOW)
    real*8, parameter :: SOLUTE_COEFF  = 3.0d0/(4.0d0*PHYS_PI*PHYS_RHOW)
    real*8, parameter :: GAMMA_COEFF   = PHYS_SHP*PHYS_NUF/PHYS_SC/PHYS_RHOW*PHYS_MW/PHYS_RU
    real*8, parameter :: ALPHA_COEFF   = -1.5d0*PHYS_NUP*PHYS_NUF*PHYS_CPA/(PHYS_PRA*PHYS_CPP*PHYS_RHOW)
    real*8, parameter :: BETA          = 1.5d0*PHYS_LV/PHYS_CPP
    real*8, parameter :: INV_BETA      = 1.0d0/BETA
    real*8, parameter :: G_WB_COEFF    = PHYS_NUP*PHYS_CPA*PHYS_SC*PHYS_RU/(PHYS_PRA*PHYS_SHP*PHYS_LV*PHYS_MW)
    real*8, parameter :: DR2DT_COEFF   = PHYS_SHP*PHYS_NUF/PHYS_SC/PHYS_RHOW
    real*8, parameter :: ONE_THIRD     = 1.0d0/3.0d0

    ! Center and width, in log10( r ) [m], of the sigmoid blending the
    ! large-droplet branch against the wet-bulb branch of the baseline.
    real*8, parameter :: BLEND_LOG_RADIUS_CENTER     = -5.5d0
    real*8, parameter :: INV_BLEND_LOG_RADIUS_WIDTH  = 1.0d0/0.15d0

    ! Numerical guards.  MIN_RADIUS keeps an out-of-distribution r <= 0 out of
    ! the many divisions by r; DIVIDE_FLOOR bounds a denominator the closed
    ! form allows to reach zero; MIN_QUADRATIC_RADIUS keeps the reconstructed
    ! r^2 positive before its log10/sqrt (the baseline radius can legitimately
    ! be exactly zero for a droplet predicted to fully evaporate, unlike the
    ! input radius the network was originally anchored to).
    real*8, parameter :: MIN_RADIUS           = 1.0d-12
    real*8, parameter :: DIVIDE_FLOOR         = 1.0d-100
    real*8, parameter :: MIN_QUADRATIC_RADIUS = 1.0d-30

    ! Largest argument exp() can take before overflowing a real*8 (~709.78).
    ! Used only to take an analytic limit in place of an infinity/infinity NaN
    ! for radii far below the trained range -- see analytic_baseline_step().
    real*8, parameter :: MAXIMUM_EXP_ARGUMENT = 700.0d0

    ! Argument below which exp() underflows a real*8 to exactly zero (~-745.13,
    ! the log of the smallest denormal).  Comparing against this and assigning
    ! zero is bit-for-bit identical to making the call, but skips a libm
    ! transcendental -- and, more importantly, skips producing a denormal,
    ! which carries a large microarchitectural penalty on x86 unless
    ! flush-to-zero is enabled.  This is not a rare path: over the trained
    ! parameter ranges exp( -k*tau ) underflows for ~52% of droplets and
    ! exp( t1 + t2 + t3 ) for ~20%.
    real*8, parameter :: MINIMUM_EXP_ARGUMENT = -746.0d0

    ! A radius equilibrium is only physically meaningful below this size; the
    ! solve works in x = 1/r, so this is applied as x > 1/MAXIMUM_PHYSICAL_RADIUS.
    real*8, parameter :: MAXIMUM_PHYSICAL_RADIUS     = 1.0d0
    real*8, parameter :: INV_MAXIMUM_PHYSICAL_RADIUS = 1.0d0/MAXIMUM_PHYSICAL_RADIUS

    ! Droplets whose classifier output exceeds this have their radius and
    ! temperature replaced by the physics-derived equilibrium.
    real*4, parameter :: EQUILIBRIUM_PROBABILITY_THRESHOLD = 0.5

    ! Reachability guard on the equilibrium substitution.  A substitution is
    ! refused -- however confident the classifier is -- unless the droplet
    ! could physically get there within this timestep:
    !
    !     | r_equilibrium^2 - r_input^2 |  <=  EQUILIBRIUM_JUMP_RATE_BUDGET*dt
    !
    ! dydt()'s radius equation is d(r^2)/dt = 2*Shp*nuf*rhoa/(Sc*rhow) *
    ! (qinf - qstar), whose prefactor is 1.28e-07 m^2/s at the top of the rhoa
    ! range; |qinf - qstar| over this parameter box does not exceed ~1e-2,
    ! bounding |d(r^2)/dt| at ~1.3e-09 m^2/s.  The largest
    ! | r_eq^2 - r_in^2 | / dt among genuine substitutions in the validation
    ! set is 1.211e-09 m^2/s, so the derived bound and the observed maximum
    ! agree; the budget below is that bound exactly, with no fudge factor.
    !
    ! Testing r^2 rather than a ratio of radii is what gives this the right
    ! shape.  d(r^2)/dt is essentially independent of r, so the reachable set
    ! is a fixed absolute window in r^2: a 10 nm droplet can legitimately
    ! cross three decades of radius in one step while a 100 um droplet cannot
    ! move by one part in 10^4.
    !
    ! The failure this stops: a 1e-4 m droplet at RH 0.40 cools to its
    ! wet-bulb 295.63 K, the classifier crosses 0.5 there, and the droplet is
    ! collapsed onto its 1.35e-8 m Koehler radius -- a factor of 7424.  That
    ! substitution implies 1.0e-07 m^2/s, 83x the largest genuine one.
    ! Raising EQUILIBRIUM_PROBABILITY_THRESHOLD only delays it.
    !
    ! Two multiplies, a subtract and a compare, and only on the branch the
    ! classifier has already fired -- which skips analytic_baseline_step()
    ! anyway, so this costs nothing measurable.
    !
    ! NOTE: Keep in sync with
    !       models.QuadraticResidualnet_scaled_layernorm_eq_classifier_analytic's
    !       EQUILIBRIUM_JUMP_RATE_BUDGET.
    !
    real*8, parameter :: EQUILIBRIUM_JUMP_RATE_BUDGET = 1.3d-9

    ! Largest *decrease* in r^2 any single substitution may make, regardless of
    ! timestep.  One-sided on purpose: collapsing a droplet onto a haze radius
    ! it is nowhere near is the damaging direction, and growth is both rarer and
    ! benign.  The largest decrease among genuine substitutions in the
    ! validation set is 2.721e-11 m^2 (p99.9 1.681e-11) while the largest
    ! genuine increase is 1.650e-10 m^2, so a symmetric cap here would cost
    ! recall and a one-sided one costs nothing.
    !
    ! This complements EQUILIBRIUM_JUMP_RATE_BUDGET rather than replacing it:
    ! the rate budget scales with dt and goes slack at the top of the timestep
    ! range, while this is an absolute floor under how far one step may ever
    ! take a droplet downward.  Both must hold.
    !
    ! NOTE: Keep in sync with models....analytic's
    !       EQUILIBRIUM_MAX_QUADRATIC_DROP.
    !
    real*8, parameter :: EQUILIBRIUM_MAX_QUADRATIC_DROP = 3.0d-11

    ! Corrections smaller than this, in the normalized units the network
    ! regresses, are treated as zero -- matching
    ! models.QuadraticResidualnet_scaled_layernorm_eq_classifier_analytic's
    ! residual_deadband constructor argument, which the reference model is
    ! evaluated with set to 1.0e-3.
    !
    ! NOTE: This gates the *radius and temperature residuals only*.  The
    !       classifier neuron is untouched, and the deadband is applied before
    !       the temperature is anchored to the analytic baseline and before the
    !       equilibrium substitution, so a substituted droplet's physics-derived
    !       equilibrium is never gated.
    !
    real*4, parameter :: RESIDUAL_DEADBAND = 1.0e-3

    ! 10**(2*RADIUS_LOG_MEAN), the scale the network's radius residual is
    ! expressed in.  Set in initialize_model() rather than declared a parameter
    ! since a real-valued exponentiation is not a constant expression, and
    ! hoisted out of estimate() so the hot loop never re-evaluates it.
    real*8 :: radius_scale_factor

    ! Weights for each of the layers.
    real*4, dimension(NUMBER_INPUTS, NUMBER_HIDDEN_LAYER1_NEURONS)                :: layer1_weights
    real*4, dimension(NUMBER_HIDDEN_LAYER1_NEURONS, NUMBER_HIDDEN_LAYER2_NEURONS)                :: layer2_weights
    real*4, dimension(NUMBER_HIDDEN_LAYER2_NEURONS, NUMBER_HIDDEN_LAYER3_NEURONS)                :: layer3_weights
    real*4, dimension(NUMBER_HIDDEN_LAYER3_NEURONS, NUMBER_OUTPUTS)                :: output_weights

    ! Biases for each of the layers.
    real*4, dimension(NUMBER_HIDDEN_LAYER1_NEURONS) :: layer1_biases
    real*4, dimension(NUMBER_HIDDEN_LAYER2_NEURONS) :: layer2_biases
    real*4, dimension(NUMBER_HIDDEN_LAYER3_NEURONS) :: layer3_biases
    real*4, dimension(NUMBER_OUTPUTS) :: output_biases

    ! Arrays to hold the intermediate results between layers.
    !
    ! NOTE: We don't do anything fancy like detecting when we could reuse an
    !       intermediate.
    !
    real*4, dimension(NUMBER_HIDDEN_LAYER1_NEURONS) :: layer1_intermediate
    real*4, dimension(NUMBER_HIDDEN_LAYER2_NEURONS) :: layer2_intermediate
    real*4, dimension(NUMBER_HIDDEN_LAYER3_NEURONS) :: layer3_intermediate

    ! Biases for each of the layernorms.
    real*4, dimension(NUMBER_HIDDEN_LAYER1_NEURONS) :: layernorm1_weights, layernorm1_biases
    real*4, dimension(NUMBER_HIDDEN_LAYER2_NEURONS) :: layernorm2_weights, layernorm2_biases
    real*4, dimension(NUMBER_HIDDEN_LAYER3_NEURONS) :: layernorm3_weights, layernorm3_biases

    ! Epsilon each layer norm adds to the variance for numerical stability.
    !
    ! NOTE: This *must* match the eps the model was trained with (PyTorch's
    !       torch.nn.LayerNorm defaults to 1e-5) and it must be added *inside*
    !       the square root -- PyTorch computes (x - mean)/sqrt( var + eps ).
    !       Adding it to the standard deviation instead evaluates a subtly
    !       different function than the one that was trained.
    !
    real*4, parameter :: LAYERNORM_EPSILON = 1.0e-5

    contains

        subroutine initialize_model()

            implicit none

            layer1_weights(1:7, 1) = [ &
-0.3053596616, -0.1677449346, -0.0471768789,  0.1337472498, -0.2958996594, -0.2328994125,  0.3258177042 &
]
            layer1_weights(1:7, 2) = [ &
-0.8460815549, -0.0609634817,  0.0069439351,  0.1156142578, -0.0640987977,  0.0053153588,  0.0312755369 &
]
            layer1_weights(1:7, 3) = [ &
 0.2651144266, -0.0735691637,  0.0097979428, -0.0050498759,  1.1993416548,  0.0123574045,  0.0984047204 &
]
            layer1_weights(1:7, 4) = [ &
-0.6059218645, -0.0942163169,  0.2177055180,  0.1741783172, -0.6712453365,  0.1767033488,  0.4538789093 &
]
            layer1_weights(1:7, 5) = [ &
 0.6858406663, -0.3798647821, -0.0111401090, -0.1899545938, -0.5602335930,  0.0805873126,  0.2659893036 &
]
            layer1_weights(1:7, 6) = [ &
 0.6953291297, -0.2618095577,  0.1545470804,  0.2217529267, -0.5705860257,  0.0326461606,  0.3303587437 &
]
            layer1_weights(1:7, 7) = [ &
-0.7093842626, -0.1399227232, -0.2085738778,  0.0682826564,  1.0588489771,  0.0238215420,  0.2372356355 &
]
            layer1_weights(1:7, 8) = [ &
 1.0865284204,  0.6532500982, -0.0573790893, -0.7826437354,  0.0617241710,  0.0323604345,  0.1582190692 &
]
            layer1_weights(1:7, 9) = [ &
-0.7127276659, -0.2932396233, -0.2490052432,  0.3933676481, -0.5646463633,  0.0025730880,  0.4088717401 &
]
            layer1_weights(1:7, 10) = [ &
 0.5634875298, -0.1102813184,  0.0464485325, -0.2516703904,  0.2763006091,  0.0363217071, -0.4353999496 &
]
            layer1_weights(1:7, 11) = [ &
 0.3090471029, -0.0928910896, -0.2175140232,  0.3030161262, -0.4406690001, -0.0351686925, -0.0702257603 &
]
            layer1_weights(1:7, 12) = [ &
 2.3346235752, -0.0740370899, -0.0891388282, -0.0780600533, -0.0386270359, -0.0004200181, -0.1215119660 &
]
            layer1_weights(1:7, 13) = [ &
-0.7302066088, -0.1481737345, -0.2918422520, -0.1941689998, -0.5153249502,  0.0351204872,  0.1489759535 &
]
            layer1_weights(1:7, 14) = [ &
 0.7333056927, -0.3019628227,  0.0954957083,  0.2079397589,  0.4068814814,  0.0744898766,  0.3264281154 &
]
            layer1_weights(1:7, 15) = [ &
-1.2284523249, -0.0623593442,  1.0883654356, -0.0095479628, -0.1054612175,  0.0153794708,  0.1492879540 &
]
            layer1_weights(1:7, 16) = [ &
 0.2086675763, -0.1196308136, -0.1632486880, -0.5216231346, -0.3569635451,  0.0449057072,  0.6000903845 &
]
            layer1_weights(1:7, 17) = [ &
 1.1056084633,  0.2120678276, -0.0344571397, -0.1585630029, -0.4469528496, -0.0062640840,  0.2085644156 &
]
            layer1_weights(1:7, 18) = [ &
-0.2706386149, -0.0692582726, -0.1441128701,  0.2527618706,  0.7696064115,  0.0016854119,  0.2154984325 &
]
            layer1_weights(1:7, 19) = [ &
 2.0779018402, -0.1254497916,  0.0265664402,  0.0081872139, -0.0080550537,  0.0212808140,  0.1018663421 &
]
            layer1_weights(1:7, 20) = [ &
-0.0463528298, -0.3248773515,  0.0278554112,  0.4505407512,  0.4254241288, -0.0229957029,  0.3209544420 &
]
            layer1_weights(1:7, 21) = [ &
-1.3645468950, -0.0576978996,  1.3879748583, -0.0352012850,  0.0290020667,  0.0188327171,  0.1068562493 &
]
            layer1_weights(1:7, 22) = [ &
-0.6050117016,  0.2142063528,  0.0795074254, -0.2321630567, -0.6148223877,  0.0173208918,  0.1211058646 &
]
            layer1_weights(1:7, 23) = [ &
-0.5966912508, -0.0797850266, -0.0062033320,  0.1656894237, -0.3589602113,  0.0046468936,  0.3786000311 &
]
            layer1_weights(1:7, 24) = [ &
-0.1053617895, -0.1851067990,  0.1467497796, -0.1229242831, -0.4600988328,  0.1442408115,  0.1079308018 &
]
            layer1_weights(1:7, 25) = [ &
 0.1159042940, -0.0488520451,  0.0099190865, -0.0292016398, -0.0750319734,  0.0194024928, -0.8976703882 &
]
            layer1_weights(1:7, 26) = [ &
 0.4168990552, -0.0830506608, -0.0038823127,  0.0360508673,  0.9341623187,  0.0119611816,  0.1306050867 &
]
            layer1_weights(1:7, 27) = [ &
-0.9014922380, -0.1340664029, -0.3153666258,  0.1264103651, -0.7026502490,  0.0335568003,  0.3236488998 &
]
            layer1_weights(1:7, 28) = [ &
-0.1839609295,  0.3139361441,  0.0509824567, -0.2847736776, -0.1021424308,  0.0366207510,  0.3730103374 &
]
            layer1_weights(1:7, 29) = [ &
 0.7050876021, -0.0401037745, -0.2776701450, -0.1713015735,  0.3962798417,  0.0137939146,  0.1385037601 &
]
            layer1_weights(1:7, 30) = [ &
 0.1688245833, -0.0463564768,  0.0045333416, -0.0269142315, -0.1174177378,  0.0190043617, -0.8590317369 &
]
            layer1_weights(1:7, 31) = [ &
 0.5133447647,  0.3808597624, -0.1497788727, -0.1963213235, -0.4734798074, -0.0358964615,  0.2470314056 &
]
            layer1_weights(1:7, 32) = [ &
-1.1621092558, -0.0771638751,  0.1065810025, -0.0471739471,  0.1516973078,  0.0201587752,  0.0387493595 &
]


            layer2_weights(1:32, 1) = [ &
-0.6658982038, -0.5775609016,  0.2066393346, -0.7911694646,  0.8790429831,  0.3381820619,  0.2304497212, -0.4618760943, -0.5948655009, -0.4466061294, &
-0.4991230667,  0.1801243871, -0.1031761914,  0.0860924646,  0.0723979771,  0.3600169420, -0.2635294497, -0.6101406217,  0.0002118583,  0.2328594327, &
 0.5559886098,  0.0828048512, -0.6323927045, -0.2080390602, -1.6897602081,  0.2211610377, -0.5797071457,  0.1171404272,  0.1453980058, -0.6364895105, &
-0.0846185833,  0.1755550057 &
]
            layer2_weights(1:32, 2) = [ &
 0.0475835837,  0.9743899107,  0.0295070466,  0.1517581493,  0.5751710534, -0.8161474466, -0.7401252985, -0.8537775874, -0.0130480183, -0.0395955667, &
-0.1566459686, -0.1828104705,  0.1129251420, -0.0701198727, -0.1499836743, -0.1063335165, -0.4415698051, -0.3148817718,  0.7213648558, -0.3795628250, &
 0.0646688268,  0.3371041715,  0.2916580141,  0.1504751742,  0.8544768095, -0.0058879666, -0.3560662270, -0.9675643444,  0.3116522133,  0.6705843806, &
-0.3707641959, -1.3285043240 &
]
            layer2_weights(1:32, 3) = [ &
-0.3647228777,  0.3591896892,  0.1055962443,  0.2179333270, -0.0685402527,  0.3723406494, -0.1245001629, -0.1622579992, -0.6793181300, -0.2217191309, &
-0.2714617550, -0.1851550639,  0.2431767881,  0.5691832900,  0.3473692536, -0.0607919656,  0.0120686432, -0.3870711327, -0.1580678076, -0.2932976484, &
 0.8066149354,  0.0532534942, -0.0585740507, -0.8635836840, -0.2299997360, -0.0566082895, -0.1019085273, -0.3116437197, -0.4264238775, -0.1936707944, &
 0.3487305939, -1.4776788950 &
]
            layer2_weights(1:32, 4) = [ &
-0.2988444865,  0.0622347966, -0.0755253881,  0.1133200601, -0.5138548017,  0.3967274725,  0.3704846203,  0.9796779156, -0.6243500710, -0.2833143473, &
 0.3223948181,  0.2798835039, -0.3703673482, -1.0566325188, -0.3980258107,  0.4704169929,  0.0751629397, -0.4006955326, -0.0713320151, -0.9618270397, &
-0.3075139821, -0.4540382326, -0.3184404075, -0.3290253580,  0.2810712755, -0.5928205252, -0.0158360004,  0.4456219375, -0.2932254970,  0.1660872251, &
 0.1919947416,  0.1658867300 &
]
            layer2_weights(1:32, 5) = [ &
-0.6847102642, -0.0680630058,  0.7917948961, -0.0405975357,  0.2369970381, -0.0193900783, -0.1668885052,  0.7125723958, -0.6223622561,  0.4634917676, &
-0.6979817152, -0.1128166839, -0.2438724041,  0.0292216558,  0.7933424711,  0.2578998208, -0.3070209026,  0.5494688749, -0.3524617851,  0.4253760278, &
-0.5846102834,  0.5082204342,  0.1146909893,  0.0823169947,  0.1544327885, -1.3087930679, -0.8940458894,  0.1389339715,  0.4654674530, -0.2976025343, &
 0.6952053308, -0.1955757141 &
]
            layer2_weights(1:32, 6) = [ &
 0.0543295257,  0.7431932092, -0.2706975639,  0.1524601728,  0.1223531812, -0.0762016103,  0.1229407415, -0.5551706553,  0.4187287688, -0.1673150659, &
-0.0943347290,  0.4663547277, -0.0984570086,  0.2114557773,  0.0882363617,  0.2987821698, -0.6625486612,  0.4490129948,  0.0698662177, -0.3480015993, &
 0.0653867349,  0.0699417591, -0.2786831558, -0.2344352305,  0.7032101750, -0.1664405018,  0.1257257611, -0.0811302364, -0.2729568779,  0.6489457488, &
-1.1202576160,  0.1892936677 &
]
            layer2_weights(1:32, 7) = [ &
 0.0759332776, -0.3765482306, -0.5451993942, -0.0614480637,  0.0159129724,  0.2182273567,  0.7073078156, -0.4010527134,  0.1635151356,  0.2326424122, &
 0.6020515561,  0.2967312336, -0.5913783312, -0.0968404114, -0.4859626889,  0.1058161557, -0.5013994575, -0.4799305201, -0.6929050684, -0.2029904276, &
-0.5443231463, -0.8648488522,  0.3306997716, -0.4552685618,  0.6446318626,  0.8123639822, -0.4252344966, -0.2665643096,  0.2907492816,  0.4457069039, &
-0.1202234775, -0.4219377637 &
]
            layer2_weights(1:32, 8) = [ &
 0.0532880798, -0.4677705169, -0.1470418572, -0.3063827753, -0.1774728000, -0.4961063564,  0.2108626217,  0.2568119466,  0.2121496797, -0.5008432269, &
 0.3414184451,  0.3875203431,  0.2169272006, -0.3322230577,  0.2418942600, -0.3866113126,  0.0279157460,  0.2442685515, -0.6880133152,  0.4975938797, &
-0.2840675116,  0.2128156722,  0.4749319553,  0.3791317344, -0.0864262059, -0.5594104528,  0.0087091913,  0.3994587958, -0.1220757067, -0.2012484223, &
 0.2055510879,  0.4126385748 &
]
            layer2_weights(1:32, 9) = [ &
 0.1360204965, -0.3007238805,  0.0068567176, -0.0779058337,  0.3045767844, -0.3809071779, -0.1470214278, -0.2282555103, -0.1654531509,  0.9373925924, &
 0.0722619295, -0.0960996598,  0.0594565608, -0.1592373252,  0.0293198861, -0.1460249722, -0.2633768022,  0.2891790569,  0.7332197428,  0.4844542444, &
-0.1991890222,  0.0307649784, -0.0991597399,  0.2633921504,  0.8792884350, -0.1932895780, -0.3229847252, -0.1884777099,  0.7401704788,  0.7109830379, &
-0.3554105759, -0.0351731144 &
]
            layer2_weights(1:32, 10) = [ &
-0.0059937630, -0.1124989465,  0.2150271982, -0.0023964052, -0.1522285789,  0.4369603992,  0.1835534871, -0.2202614993, -0.1562983543,  0.9215308428, &
 0.2188064158,  0.3420313001,  0.0239104312,  0.1201135442,  0.3417529762,  0.3532731533, -0.6845173836, -0.2014649808,  0.4389016330,  0.1721697152, &
 0.3272480965,  0.1708977073, -0.0602342561,  0.0637809113,  0.6249623299, -0.3124752939, -0.2175744772,  0.3049451709,  0.3651511371,  0.7547746301, &
-0.2718239725,  0.1410914510 &
]
            layer2_weights(1:32, 11) = [ &
 0.2087815255, -0.1316907108, -0.0967227668,  0.0212280881, -0.1045106351, -0.5451475978,  0.1697195917, -0.4091026187,  0.0364630036, -0.5429930687, &
-0.8257246017,  0.3884055614, -0.2545804381,  0.3026269078,  0.0226018243, -0.4576734304,  0.2172706574,  0.4566062093,  0.0617038049,  0.2843363285, &
-0.0007346576,  0.5127888918,  0.8705790639, -0.2957795560, -0.5822312236,  0.0529778227,  0.0953367352,  0.0519825928, -0.2011293173, -0.7487571836, &
-0.2474268526, -0.2213481516 &
]
            layer2_weights(1:32, 12) = [ &
 0.5284461975, -0.8587071896,  0.1747200638,  0.9649230242, -0.2702141404,  0.1718745679,  0.3966224194,  0.6114151478,  0.6394807696, -0.3046536446, &
-0.1333673894,  0.0631566197,  0.1782085299, -0.3874773383,  0.3158984780, -0.3588083088, -0.1962575912, -0.3349628747,  0.6956555247,  0.1440628022, &
-0.1868164390, -0.5350760818, -0.0633383244, -0.1938830167, -1.0867270231,  0.1382076293,  0.1672330052,  0.4498303831, -0.5191545486, -0.6572352052, &
-0.6831036806, -0.0827132985 &
]
            layer2_weights(1:32, 13) = [ &
-0.2338428795,  0.0556357652,  0.0423140489,  0.0769115239,  0.0085799620,  0.6925046444, -0.5547426343, -0.2435153723,  0.4307669699,  0.5502691865, &
 0.2760075033, -0.6561412215,  0.1139024571,  0.1417308450, -0.4473777115,  0.0394509137, -0.7571974993, -0.3527289927, -0.4091548920, -0.2522106767, &
-0.4004109800, -0.1828059852, -0.3686431646, -0.2718205452, -0.0252487920,  0.1365344673, -0.0070566735, -0.2329104543, -0.0844836235,  0.0846110955, &
 0.7735314965, -0.5053626895 &
]
            layer2_weights(1:32, 14) = [ &
-0.1281652451,  0.3534629047,  1.7573586702,  0.3157685101, -0.4177516401, -0.3009643555, -1.3054659367, -0.0357054174, -0.5743518472, -0.1092331111, &
-0.3584809005, -0.1702596694, -0.9805908799, -0.0445479229,  0.5102636814,  0.8683767915, -0.1909085959, -0.2965073884, -0.0917888731,  0.4157585800, &
 2.1897313595, -0.2709904313,  0.4753399193,  0.3932938278, -0.1591400355, -1.1089290380,  0.7755078673, -0.2295568138, -0.1984215826,  0.1844068319, &
 0.8436486721,  0.6560268402 &
]
            layer2_weights(1:32, 15) = [ &
 0.2712433636,  0.7143108845, -0.4252689779, -0.4836995006, -0.1665233523, -0.2095740885,  0.8164356947,  0.0680779591,  0.1518326104,  0.1558245718, &
 0.3085845411,  0.3338984549,  0.3946513534,  0.5885357857, -0.6147840619, -0.0170354042,  0.7710433006,  0.1266639531, -0.6899425387, -0.6118305326, &
-1.2226070166,  0.4691349864, -0.8676812649,  0.4088329971, -0.0371969678,  0.8094595075, -0.0118247196,  0.1564826816,  0.2309070528,  0.0605415627, &
-0.8864933848, -0.2362128496 &
]
            layer2_weights(1:32, 16) = [ &
 0.0075290441, -0.0510755554,  0.0027530619,  0.5442562699, -0.1327576935,  0.4314221740, -0.4980671406, -0.4421786666,  0.3471372426,  0.1040830389, &
 0.1400915384, -0.1852466613,  0.0891614556,  0.0313382745,  0.4212035835,  0.0793621913, -0.4544664621, -0.5757279396,  0.2450013608, -0.1099115610, &
 0.2665848136, -0.3628162742,  0.2212606221,  0.3357971013, -0.5636883378,  0.0345461033, -0.0207203366,  0.5999906063,  0.3994428217, -0.5736617446, &
 0.0887781307, -0.2467778325 &
]
            layer2_weights(1:32, 17) = [ &
 0.0340651944, -0.2162951678, -0.0841596648, -0.1997583061, -0.7819840908, -0.1707317680,  0.5597062111,  0.4105817080, -1.0616357327, -0.1555308849, &
-0.4782733917,  0.2159966230, -0.3380229473,  0.7958860993, -0.2145345956,  0.2590116858,  0.8784447312,  0.1718607694, -0.2361156493, -0.6061644554, &
-0.0746129304,  0.9689897299,  0.0336928554, -0.5734040737, -0.5762456656, -0.1773172766, -0.1403668672, -0.3365688920,  0.1506120861, -0.2694624662, &
 0.6747448444,  0.2558008134 &
]
            layer2_weights(1:32, 18) = [ &
-0.4341239929,  0.3180296123,  0.4225107133, -0.1632393748,  0.3380107880,  0.1222677082, -0.0335519686, -0.2999544740, -0.0009425345,  0.3628939390, &
-0.7007725835,  0.2116086334,  0.1874698400,  0.1485740393, -1.3000028133,  0.2043632120, -0.3368970752,  0.2361460924, -0.0096137188, -0.4049027264, &
-1.3478217125, -0.6819640994, -0.3897924125, -0.6186786294,  0.5216747522, -0.5202432871,  0.2508503497, -0.3999328613,  0.4980012476,  0.3934065104, &
-0.0964804292, -0.1244542450 &
]
            layer2_weights(1:32, 19) = [ &
-0.0448391773,  0.2975025773, -0.4811990559, -0.0710205808, -0.1266057938,  0.0751793906, -0.6900405884, -0.2671819329,  0.4511502385,  0.0539417006, &
-0.0059935609, -0.7347399592,  0.2714109123, -0.4737204909, -0.2558674812,  0.2576014102,  0.1223601475, -0.3573140800,  0.3364630342, -0.0283855889, &
-0.2733455300, -0.0416481756, -0.0240689274, -0.2169398516, -0.1860185266,  1.1978234053,  0.1062061861,  0.4136897326, -0.3118260503,  0.1669342667, &
-0.2155001163,  0.5574777722 &
]
            layer2_weights(1:32, 20) = [ &
 0.6461678147, -0.0963647142,  0.0632279590,  0.5344107151, -0.3759887218,  0.2141072899, -0.3564883769, -0.0004404832,  0.2461743206, -0.4063365161, &
 0.1614996940,  0.0133984648,  0.0967743173,  0.2657229900,  0.0899057761, -0.3961764276, -0.5191171765,  0.0220005326,  0.1839175522,  0.1658617258, &
 0.0995806381,  0.0322622433,  0.3456720114,  0.2763059139, -0.6932232380,  0.1738395840,  0.4305207133,  0.4057902694, -0.2654694021, -0.5496830344, &
-0.0363079347, -0.9095069766 &
]
            layer2_weights(1:32, 21) = [ &
-0.5326912403,  0.4192903638, -0.0288304277, -0.1254543513, -0.2154383659,  0.5414867401,  0.2806110382,  0.3043684959, -0.0590397976, -0.5217823982, &
 0.1332929432, -0.3056924939,  0.5066258311, -0.3447342515, -1.3955690861, -0.6199586987,  0.1939409971, -0.2904596031, -0.3110469282, -0.4517312050, &
-1.8848723173, -0.1093146428, -0.0009212738, -0.4249666929, -0.6566653848,  0.1630374342,  0.1517609209, -0.1768323630,  0.5952011347, -0.3987036049, &
-0.3865031600, -0.5109317899 &
]
            layer2_weights(1:32, 22) = [ &
 0.1700312346, -0.3695894182, -0.3409555554, -0.1479989439,  0.2964494526, -0.6106591821, -0.4286084175, -0.5522720218,  0.2044214308, -0.2861302495, &
 0.2698621750, -0.1638022512,  0.0423941985,  0.4618633986,  0.0652534664,  0.1970613301, -0.2617882788, -0.0322491936,  0.3708147407, -0.0883703381, &
 0.5258276463, -0.0660969093, -0.2632705867,  0.9024708867, -0.9361285567,  0.1284791529,  0.2749296725,  0.2418669462, -0.2348462194, -0.5953939557, &
-0.0534460619,  0.5477094650 &
]
            layer2_weights(1:32, 23) = [ &
-0.6112630367,  0.5888841152,  0.1859686822, -0.3947473764,  0.6284936666,  0.0211972557,  0.2595353425, -0.2554134429, -0.3038992584,  0.1044823304, &
 0.0046142917,  0.5450165272, -0.8406756520, -0.3329210877, -0.1913061887,  0.2219612151,  1.2123857737, -0.2855168581, -0.3563380837,  0.2070891261, &
-0.1050971076, -0.5285347700, -0.1292850226, -0.3263906538,  0.6541142464, -0.4617053866, -0.4626362920, -0.6469336748,  0.3368364573,  0.3840854466, &
 0.0265356451,  0.1177119836 &
]
            layer2_weights(1:32, 24) = [ &
 0.0586024821,  0.1409051269,  0.1494355947, -0.1594636291,  0.6421658993, -0.2621418536, -0.9742026329, -0.4812521338, -0.6777573228, -0.0176443439, &
-0.1499646455, -0.0885049179,  0.0491012000,  0.5589722991,  0.1187374890,  0.0427784994,  0.4145359993, -0.5405738354, -0.0541135296,  0.2501697838, &
 1.5265810490, -0.5419602990, -0.0555038154, -0.1549518704, -0.1853513420, -0.5831834674,  2.0831048489, -0.0938977078, -0.1325240284,  0.0517432652, &
 0.6358923912, -0.2078731060 &
]
            layer2_weights(1:32, 25) = [ &
-0.1272094995,  0.0165625960,  0.0990971327,  0.1176078841,  0.0130674401,  0.1277249306, -0.2663118243, -0.2703045309,  0.4372011125,  0.5611429214, &
-0.0894309953, -0.4633431435, -0.3438835740,  0.1242389455,  0.8606199622,  0.4902411997,  0.1062496677, -0.4277083278, -0.2024309486,  0.0433401763, &
 0.5450986624,  0.1785091758, -0.8269601464,  0.1683606654, -0.3782552779,  0.1269517392,  0.1166994572,  0.0006969538, -0.2508027554, -0.1456197351, &
 0.2282488495, -0.7837808728 &
]
            layer2_weights(1:32, 26) = [ &
-0.1244699433, -0.0144473277,  0.0926727280,  0.2451821566, -0.2255043983,  0.0474997759, -0.3735604584,  0.4927512109, -0.5085273981,  0.0533017479, &
 0.2316851169, -0.4311025441, -0.3198814094, -0.1996039003, -0.0932138935,  0.2304557711, -0.1515255421,  0.2867057323,  0.0513902418, -0.4952263534, &
 0.0432258919, -0.0087364083, -0.1506539583, -0.3843104243,  1.7807325125,  0.1052381992,  0.2148815095, -1.2128988504, -0.3457944393,  0.6832858920, &
 0.2489734590, -0.0933937803 &
]
            layer2_weights(1:32, 27) = [ &
 0.0647558793, -0.2926279604,  0.0849769115, -0.0349892974,  0.6682610512, -0.3188824952,  0.2170228511, -0.4540883005, -0.2037247866,  0.0119548943, &
-0.8508668542,  0.2506489456, -0.9091124535, -0.2707845867,  0.1262170523,  0.0300138108, -0.5322156549,  0.6738920808, -1.0159388781,  0.3542879820, &
 0.0807543546,  0.0448003039, -0.3235066533, -0.0598572828, -0.2090853900, -0.0002045316, -0.3190823197,  0.0408107340,  0.2898485959,  0.0491202883, &
-0.0871746689, -0.6599376798 &
]
            layer2_weights(1:32, 28) = [ &
 0.3627490699, -0.9903566837,  0.0028560413, -0.0362008661, -0.7222442627, -0.9817250967,  0.0154828904,  0.6213288307, -0.6615114808, -0.3116860688, &
 0.1968411952,  0.0361404493,  0.4041315615,  0.1616764069, -0.1469746083,  0.4303091764,  0.8440622091,  0.6376429200,  0.4943447709, -1.3752601147, &
-0.1707313061,  0.4373311698,  0.9030922651, -0.2332814783,  0.5032384396, -0.3069398403, -0.3414257765, -1.4646289349, -0.9710463881,  0.4891600311, &
-0.6334825754,  0.4967284203 &
]
            layer2_weights(1:32, 29) = [ &
 0.4915971458, -0.9321557283, -0.7456286550, -0.3702961504, -0.3215049803, -0.5512695909,  0.0632053614, -0.5552802682, -0.0855891034,  0.2350587398, &
 0.0858508497,  0.4554469287, -0.5069884658,  0.9033113122,  0.0680886135, -0.1202006266,  1.2906125784,  0.2976231277, -0.5449352264, -0.1110413745, &
-0.7701646090, -0.2110158503, -0.1887893528,  0.7172918320, -0.7047261596,  0.5143559575, -0.5042130351, -0.7619341612, -0.0024945044,  0.1940671355, &
 0.3387086987, -0.3814236820 &
]
            layer2_weights(1:32, 30) = [ &
 0.2713333666,  0.6442569494,  0.3077741265,  0.5393892527, -0.2601904273, -0.0987770110,  0.3764178157,  0.2172206193,  0.0124508124, -0.4680612683, &
-0.3990978897,  0.3134582639,  0.0536159910, -0.5293971300,  0.0561958179, -0.2942871153,  0.8443901539, -0.0087203849, -0.7256175876, -0.2262375355, &
 0.0177027173,  0.3375473022,  0.6497747302,  0.0504684709,  0.2838114202, -0.4658496380,  0.2821975350, -0.1092969030, -0.6611810923,  0.1547905505, &
 0.1029620245,  0.3116666675 &
]
            layer2_weights(1:32, 31) = [ &
-0.0527874902,  0.1963787973, -0.4921331406,  0.0171207692, -0.3105016947,  0.0749643445, -1.1510082483, -0.2163191885,  0.8085182905, -0.1396714449, &
 0.4578678310, -1.2528755665,  0.6154695153, -0.0722583532, -0.0388441384, -0.0479562022, -0.5275562406, -0.4466799200, -0.1374080777, -0.4666068256, &
-0.1718227863, -0.0237662699, -0.2357656956,  0.2076628804, -1.0869570971,  0.9971446395,  0.2659925818,  0.1030752510, -0.4166015685, -0.8061823845, &
 0.2825762928, -0.2635337114 &
]
            layer2_weights(1:32, 32) = [ &
 0.1045267433,  0.1455772966,  0.6346700191, -0.0053712362, -0.1004003659, -0.0606899187,  0.2578444779,  0.0962643847,  0.1221679300, -0.5597605705, &
-0.7113547921,  0.2241965234, -0.0391545147,  0.0663413033, -0.4034022987, -0.4477626383,  0.6510378718,  0.4506618977, -0.3573408425,  0.1572681665, &
-0.2901439369, -0.3657703698, -0.0987103656,  0.1224665269, -1.3877053261, -0.6338616014,  0.0553189032,  0.9234970212,  0.0959466621, -1.1286751032, &
 0.2104232758,  0.4880422652 &
]


            layer3_weights(1:32, 1) = [ &
 0.1752545089,  0.5743162632,  0.0256520826, -0.0067988369,  0.1200271323,  0.1153343543,  0.1523967832, -0.2479643077,  0.3498137891,  0.3935188651, &
-0.2033615559, -0.0809258819, -0.0317694508, -0.0735931396,  0.1826032251, -0.2185885906, -0.2489882410,  0.3978149593, -0.1086208001,  0.3342131078, &
-0.2920743525, -0.0112813497,  0.3082209826,  0.1097420454, -0.4093661904,  0.6147727966, -0.0808617920,  0.1274194270, -0.0310163274, -0.3073954284, &
-0.2667256296,  0.1546215117 &
]
            layer3_weights(1:32, 2) = [ &
 0.0585125647,  0.1084872633,  0.1350411177, -0.0705268607,  0.2444234639,  0.6428191662,  0.1700006872, -0.1865969449,  0.2311025560,  0.1891046613, &
-0.3123674393, -0.1406591982,  0.7530844808, -0.0385099910,  0.1927111596,  0.0140538299,  0.1449292004,  0.1008295193,  0.1023920849,  0.3133426309, &
-0.1876104474, -0.1717959195,  0.1925085932,  0.0466913246, -1.1714750528,  0.4795017838,  0.1259925216,  0.0121911466,  0.3601619899, -0.4210935235, &
-0.3199536204,  0.0899115279 &
]
            layer3_weights(1:32, 3) = [ &
-0.2058426589, -0.3717071712, -0.5152778029,  0.6609444022,  0.3138653040, -0.6518722177, -0.2377254516, -0.4867917895, -0.2962858975, -0.1689890325, &
 0.0213253051,  0.1820214242, -0.1577446759, -0.0626847818,  0.0871875957, -0.3261232972, -0.0094418228, -0.0971217155, -0.0054705339,  0.0490109138, &
-0.3531533182, -0.3159359396, -0.2983318567, -0.0129477978, -0.6168447733, -0.5114644766,  0.1577186584, -0.4873442352,  0.1664407551,  0.3311475217, &
-0.2778453231, -0.1400605440 &
]
            layer3_weights(1:32, 4) = [ &
-0.0543146804, -0.3680486679, -0.7959510088, -0.1072085723,  0.0161960684, -0.0351490900, -0.3217689693, -0.1328791827, -0.2549730837, -0.2802433670, &
 0.3243873715, -0.2485687733, -0.0043223179, -0.0543276481,  0.0691151693,  0.4365023375,  0.2177718133, -0.1217941120,  0.1351657808,  0.1793628037, &
 0.1316601634, -0.3770616949,  0.1499542296,  0.0381080732,  0.3421945274, -0.6678996086, -0.0939084888, -0.0710624978,  0.1401636600,  0.6895596981, &
 0.6945889592, -0.1473900676 &
]
            layer3_weights(1:32, 5) = [ &
-0.2061367333, -0.4318131208, -0.7661420107, -0.1380769908,  0.2114400715,  0.0506942831, -0.4397426844,  0.2250967473, -0.3371509016, -0.1084896475, &
 0.0159679577,  0.5166057944, -0.1966768801, -0.0600521453,  0.0211917460,  0.4922364950,  0.0087152999, -0.3385541141,  0.2087547928, -0.5159048438, &
-0.4142966866, -0.4331319630,  0.0461257137,  0.0105531393,  0.8459030986, -0.2815104127,  0.3222350180, -0.1711269617, -0.0067715272, -0.0642527044, &
 0.4857278466, -0.2252985835 &
]
            layer3_weights(1:32, 6) = [ &
-0.1811898649,  0.0782392845,  0.0071154805, -0.2251618505,  0.4677296579,  0.2476400584, -0.1556818038, -0.0767449290,  0.0705410466,  0.1345474571, &
-0.0583590157,  0.2131730765, -0.6940552592, -0.1959939152, -1.7146855593, -0.5996916294, -0.4942751527,  0.4359059036,  0.0543584041,  0.1318774968, &
 0.8876412511,  0.2047703564,  0.1853047460, -0.9849461913, -0.0103656240,  0.1673575491, -0.1623662412,  0.0726570114, -0.0132256895, -0.2052657604, &
 0.0531733371, -0.6210526228 &
]
            layer3_weights(1:32, 7) = [ &
-1.0308066607, -0.1246650144, -0.0565293096, -0.1647697240, -0.8675619364, -0.3920701742, -1.1981455088,  0.3250929117, -0.0732608736, -0.2783084810, &
 0.1793851405, -0.3137356937, -0.0716056600, -0.0304141603,  0.5779843926,  0.4683605731,  1.3718440533,  0.8677371144,  1.3742812872, -0.3692538738, &
 0.9359028935,  0.4253317416, -0.2079085261, -0.5164814591,  0.0442555808, -0.6596032381,  0.5239640474,  0.0309472941, -0.7889341712,  0.0276935510, &
 0.5669301152, -0.8543868065 &
]
            layer3_weights(1:32, 8) = [ &
 1.5245938301, -0.2427281141, -1.0976814032, -0.5862665176,  1.1882174015, -0.5003369451,  0.3094734848, -0.9456133246, -0.1194212437, -0.0114299553, &
 1.9823305607, -0.3381042182, -0.4816832244,  0.0119417831, -0.4753135741,  0.7263068557, -0.6373209357,  0.0065155737, -0.2758265734,  1.0897766352, &
 1.0167686939,  0.4496901035,  0.3508677185, -0.0937488079, -1.4803850651,  1.2447170019, -0.8319184780,  0.8323832154,  0.9559611678,  0.9121087193, &
-0.9038925171, -1.1433838606 &
]
            layer3_weights(1:32, 9) = [ &
-0.0864665434, -0.5653948784,  0.1760425568, -0.3461814225,  0.1704187542,  0.5037732720, -0.0787266642, -0.4433238506, -0.0662000477, -0.4726831317, &
-0.3223567009, -0.3347332776,  0.2593351901, -0.0547254086,  0.2509163916,  0.0950214267,  0.2603312135, -0.0355546325, -0.1740455329,  1.0997048616, &
-0.1614220440, -0.2261521965,  0.3341490328,  0.0832497180,  0.2612820864, -0.2806070447,  0.1514697969, -0.2300512493,  0.2679251134,  0.9751662016, &
 0.1544670314, -0.2907871902 &
]
            layer3_weights(1:32, 10) = [ &
-0.1090234965,  0.1416007131, -0.0967953131,  0.2979275584,  0.0630516559,  0.1451299638, -0.1233390421, -0.0461902358,  0.0905849263,  0.1951950192, &
-0.0407731310,  0.0183966774, -0.5551373363, -0.0817254931,  0.2766850293, -0.4356749058, -0.3319582939,  0.0732885227,  0.3398032486,  0.1064890698, &
-0.5259032249, -0.3440838754,  0.0368774161,  0.2582334876,  0.4502786398,  0.0160585027, -0.2186054289, -0.1313364655,  0.3592081070, -0.5211836696, &
 0.6510049701,  0.1448710710 &
]
            layer3_weights(1:32, 11) = [ &
 0.1532865465,  0.5908288956, -0.8566957116,  0.4711778164,  0.1967783421,  0.1269750297, -0.2452398539,  0.3248950243,  0.5871496797,  0.2766405046, &
-0.1093517765, -0.0407676585, -0.2878298461, -0.0627334565,  0.7495483160, -0.5365292430, -0.9650561213, -0.4270487726, -0.3264350295,  0.6475688815, &
-0.3604191244,  0.7864161730,  0.4034159482,  0.2388088256,  0.2039573789,  0.4517228901, -0.4735218287, -0.0590648130, -0.7223618627, -0.7365739942, &
 1.0707942247,  0.0848948881 &
]
            layer3_weights(1:32, 12) = [ &
 0.8894057274, -0.4384332895,  0.1433601081,  0.1099454239, -0.0965358242, -0.4060892165,  0.4634721279, -0.9935749769, -0.2586021423,  0.4682649076, &
 0.7162598372, -0.4489650130,  1.5820367336, -0.1234484389,  0.1019524783, -0.2477082163, -1.9349325895, -0.1656903177, -2.0920896530,  0.6172586679, &
 0.2274804711, -0.4182477295,  0.0873483717,  0.4936733544, -2.0687503815, -0.6028929949, -0.0108486321,  0.5136116147, -1.1399909258,  0.8023759723, &
-2.5465614796, -1.1588875055 &
]
            layer3_weights(1:32, 13) = [ &
 0.1506900638,  0.6881510019, -0.4076221883, -0.0555561483, -0.0600476414,  0.5234524608,  0.0795806721, -0.1939338148,  0.3957154453,  0.3875547945, &
-0.0482513942, -0.3402794302, -0.5957956910, -0.0405391119,  0.0849956945,  0.1790113300,  0.0912600011,  0.7638275027,  0.1961269528,  0.4352946281, &
-0.3521674573,  0.1192401126,  0.4769670963, -0.0411636122,  0.1168763414,  0.6578278542, -0.3262600303,  0.1300252527,  0.3620907962, -0.6437354684, &
-0.1987611651,  0.4152908623 &
]
            layer3_weights(1:32, 14) = [ &
 0.2534950674,  0.5392444730, -0.0176960323, -0.0109330323,  0.1441311240,  0.1534339041,  0.1088271886, -0.1223166957,  0.3748235703,  0.4470486045, &
-0.1933628023, -0.0998075157, -0.0473756604, -0.0708994642,  0.1533270478, -0.1675064713, -0.1692847461,  0.4563511908, -0.0426993482,  0.2746030986, &
-0.3181631267,  0.0408027805,  0.2054307759,  0.0931125432, -0.4071165919,  0.6808755398, -0.1466315389,  0.1364350319,  0.0125793591, -0.3649104238, &
-0.2169326693,  0.1525779068 &
]
            layer3_weights(1:32, 15) = [ &
 0.1320893168, -0.1820797175,  0.2118970007,  0.0657104030,  0.0038908864,  0.1152418777,  0.1649420261,  0.4142333269, -0.2501264215, -0.1886804849, &
-0.5877212882,  0.0807369053,  0.3862297833, -0.0684348792,  0.1502190828, -0.1057304144,  0.2368874848, -0.3185243309, -0.0207686406,  0.2240051478, &
-0.0935514942, -0.0928561464, -0.3782057464,  0.0728845820,  0.2481977493,  0.0163023379, -0.4647444785, -0.1198078319, -0.1125467718,  0.0057543307, &
-0.0651350766,  0.0963789448 &
]
            layer3_weights(1:32, 16) = [ &
 0.0122087318,  0.1517729610, -0.1499326378, -0.1204212829, -0.0799740329,  0.2093718052,  0.3253128231, -0.0319913179,  0.2530243993,  0.2971497178, &
-0.4473086298, -0.6013099551, -0.5793429017, -0.0474251360, -0.0182563495, -0.1161637902,  0.2332041562,  0.0629971400,  0.1726990193,  0.5799385309, &
-0.3776423931,  0.0593751892,  0.2430562675,  0.2233891785,  0.0590126477,  0.3920163810,  0.0618626401,  0.0911337286,  0.0174664576,  0.1178329811, &
-0.1075810865,  0.1610542089 &
]
            layer3_weights(1:32, 17) = [ &
-0.5697289705,  0.3146049380, -0.3562721610, -0.1386590749, -0.1851593256, -0.2109187990, -0.6623454690,  0.3014390767, -0.0342583619,  0.0696211383, &
-0.2313569188,  0.2476373017, -0.4813804030,  0.0038252864,  0.2822815776, -0.3664161563, -0.4511936605,  0.4087000489,  0.2013276517, -0.0717644170, &
 0.4711460471,  0.0237763841,  1.1746309996, -0.1050650924,  0.2874828875, -0.0692541599, -0.1660856158, -0.2459722161,  0.7672478557, -0.5079728961, &
 1.6652494669,  0.3618832827 &
]
            layer3_weights(1:32, 18) = [ &
 0.0574064143,  0.1312422007,  0.1329788715, -0.4556195438, -0.0206818879,  0.5663418174, -0.0125587340, -0.2613469958,  0.2060137391,  0.3184122741, &
-0.2596820295,  0.0986752287,  0.4412485659, -0.0542809144, -0.1236531734, -0.1094018593, -0.0468668304,  0.1488560736, -0.0005231137,  0.2766241133, &
 0.2379200310, -0.3341718018,  0.4596455693, -0.1247204319, -0.2634941339,  0.3604756296, -0.0474697649,  0.1783591062, -0.2942211628, -0.2893821895, &
-0.3788132668,  0.0793354511 &
]
            layer3_weights(1:32, 19) = [ &
 0.2802215815,  0.6208913326, -0.0107985446,  0.0662040040,  0.1298580021,  0.0378673561,  0.0395334587,  0.0932904854,  0.4624208212,  0.5521807075, &
-0.2123532742, -0.0850844681, -0.2483998239, -0.0725700334,  0.2964348197, -0.3131599128, -0.3928456903,  0.3895234764, -0.1254469603,  0.3094998300, &
-0.3073994815,  0.0953010395,  0.2461973429,  0.0013274188, -0.4638670683,  0.7524375916, -0.3206964135,  0.1732304096, -0.2826717198, -0.5001314282, &
-0.2025852650,  0.1024979725 &
]
            layer3_weights(1:32, 20) = [ &
 0.0592157654,  0.1986722201,  0.0966058597,  0.0119037554, -0.0087542385, -0.1178862527,  0.3215327263, -0.3499998152,  0.0987947583,  0.0625947267, &
-0.2240275145,  0.3695118129, -0.0324681513, -0.0494931862, -0.1104585007, -0.0322640613, -0.2816749811,  0.1219671443, -0.3443822861, -0.1389800906, &
-0.1894848645, -0.5743574500, -0.1588571221, -0.2635014057, -0.4193315208,  0.4313965142, -0.0051912358, -0.2294356972, -0.2937413454, -0.2078380585, &
-1.1813056469,  0.2549604177 &
]
            layer3_weights(1:32, 21) = [ &
 0.4104624689,  0.3390156925,  0.1383031905,  0.1607703269,  0.4105259776,  0.2920967042,  0.1672867537, -0.2362986505,  0.3284156024,  0.1228960305, &
 0.0409543999, -0.5003237128,  0.7129456997, -0.0437394045,  0.1223086640,  0.3099940121, -0.1651325673,  0.2655169070, -0.2141683549,  0.1715689301, &
-0.1121997535,  0.4182934463,  0.0234354492, -0.0056233699, -1.6333740950,  0.1496223509, -0.0795305222,  0.0699902996,  0.5608521700, -0.4473631680, &
-0.5825250149, -0.0076059578 &
]
            layer3_weights(1:32, 22) = [ &
 0.8696426153,  1.8959922791,  0.3735540807, -0.1323478371,  0.0347405672,  0.2206029892,  0.5702873468, -0.1393366307,  1.5362337828,  1.4205554724, &
-0.5753857493,  0.1745404452, -1.0609164238, -0.0601332672,  0.0830089152, -0.1968603730, -0.9572515488,  1.2531543970, -0.1502237469,  0.0945255905, &
-0.1267376989, -0.2549386024,  0.1633872688, -0.6020004749, -1.7834950686,  2.4856932163, -1.2360340357,  0.8908916712, -0.6304830313, -0.8902813196, &
-3.3338449001,  0.3422254920 &
]
            layer3_weights(1:32, 23) = [ &
-0.0129801203, -0.1625495255,  0.4098639488,  0.0967200249,  0.2168371826, -0.0220907442, -0.1822608858, -0.8664832115,  0.1567554772, -0.3119398057, &
-0.0219120402,  0.3789194822, -0.3058800101, -0.0650556684, -0.1438072324, -0.4505388141,  0.0176216029, -0.1183530986, -0.3430877328, -0.1382637620, &
 0.3325929642,  0.4992910326, -0.1307050735, -0.0235006604, -0.2024607956, -0.0616430305,  0.4751628339, -0.1104979813,  0.1990076005,  0.3379193842, &
-0.3167460263, -0.0644099563 &
]
            layer3_weights(1:32, 24) = [ &
-0.3662011921, -0.3865895569,  0.4675296843, -0.7874480486,  0.1122694910, -0.1450347304,  0.7460694909,  0.1511648297, -0.6485035419, -0.0034282128, &
 0.0242980998, -0.4964768291, -0.3426163793, -0.0601880290, -0.4467782974, -0.8742879629,  1.2466360331, -0.2571338415, -0.6118624210, -0.2587859333, &
-0.0844981819, -0.0653775111, -0.9881251454, -0.0565154254,  0.0416597836, -0.1356771737,  0.1280111074,  0.0243740603,  0.2704447210, -0.0011646121, &
-1.0765775442, -0.4819100797 &
]
            layer3_weights(1:32, 25) = [ &
 0.0898931921,  0.6604868174,  0.6086969376, -0.1038564965, -0.1877111942,  0.3322260380,  0.2746137381, -0.3793335855,  0.3153455853,  0.4273795187, &
-0.2381626070,  0.0805717856,  0.1246504337, -0.0755660534, -0.0307443831, -0.2683098018, -0.0119754737,  1.0364469290, -0.1511851996,  0.3380504251, &
-0.0054746070,  0.0253661107,  0.5735106468,  0.1870479584, -0.4311735630,  0.4382857382,  0.1330822557,  0.0468126759,  0.2135348618, -0.2221331745, &
-0.3038648367,  0.1949435771 &
]
            layer3_weights(1:32, 26) = [ &
 0.6900398135,  1.3425866365, -0.5996292830,  0.4418425858, -0.1961626112,  0.3350492418, -0.0061126715,  0.5336905122,  1.2970954180,  1.1250497103, &
-0.4806473255, -0.1933795959, -0.8076707125, -0.0758939683,  0.3128399253, -0.5562221408, -1.2434877157,  0.5628972054,  0.0107024768,  0.0311698616, &
-0.2095052004,  0.4533306360,  0.1949736476, -0.0129823871, -0.3832981884,  1.6031360626, -0.9632022381,  0.4369560778, -0.6806138158, -0.9966031909, &
-0.1851732135,  0.3169670105 &
]
            layer3_weights(1:32, 27) = [ &
-0.2674722970, -0.2720527649,  0.6062532663, -0.1077017859,  0.0152359642, -0.2889300585,  0.0291922521, -0.3316605687, -0.3205530643, -0.3927868009, &
 0.5578596592,  0.3885671794,  0.0944674835, -0.0635061339, -0.0424912162,  0.4579960108, -0.3536268771, -0.1448484659, -0.2178955823, -0.8721886277, &
-0.0547693893, -0.1843401641,  0.0717092305,  0.0677006319, -0.0117738741, -0.6623377800,  0.4971667528, -0.1850941628,  0.4159120619, -0.5123657584, &
 0.5392752290,  0.1616529673 &
]
            layer3_weights(1:32, 28) = [ &
 0.1708481163,  0.3494137824,  0.0600153692, -0.1245244741, -0.1112342849,  0.1272248626,  0.1655636579, -0.1967460066,  0.2400894910,  0.2846117616, &
-0.1644064337, -0.7715778351, -0.8033620119, -0.0658548027, -0.1764256358,  0.0418278128, -0.1337949634,  0.1219498441,  0.1265349835,  0.4913100600, &
-0.4144272506,  0.0806409940,  0.2709743977,  0.2578369975,  0.4594114423, -0.2128853202, -0.2202530205,  0.1581952125,  0.1473954469, -0.4733442366, &
 0.1072211713,  0.2239027023 &
]
            layer3_weights(1:32, 29) = [ &
 0.0317192785, -0.1210985780, -0.1772081107, -0.3024865687,  0.0209934395,  0.2510185540,  0.1099427566,  0.3789760470, -0.1662943810, -0.0832868442, &
 0.2914465964,  0.0371524505,  0.1672569960, -0.0661598966,  0.0846034437, -0.1468485296, -0.0540897176, -0.1383367628, -0.0161174424, -0.3793746829, &
-0.0752936527,  0.0151554570,  0.0268185679,  0.0589485392,  0.1723454446,  0.1252364218, -0.2524614334, -0.0291923359, -0.0418823734,  0.1303931028, &
-0.0472829379,  0.2458102852 &
]
            layer3_weights(1:32, 30) = [ &
 0.0983342230, -0.0981691927,  1.2093881369, -0.1017562449,  0.1273813248,  0.0102056935,  0.0729947835, -0.3567847908, -0.1420665085, -0.0818968192, &
 0.4448531270, -0.9688748121, -0.0823707730, -0.0661013201,  0.0890916213, -0.2570189834,  0.0736250058, -0.0861615464, -0.3266593218,  0.6045893431, &
-0.0766462758,  0.0707242936, -0.0432817005,  0.0027956318, -0.4137606919, -0.4497144520,  0.0702725947,  0.0488651916,  0.3664234877,  0.5742235184, &
-0.2051248848, -0.2017574906 &
]
            layer3_weights(1:32, 31) = [ &
 0.3000456393, -0.8229750395, -0.3720369041,  0.8952672482,  0.9488385916,  0.0866345018,  0.0347230062, -0.1241935566,  0.6447931528,  0.1518963724, &
-0.9376788139, -1.0585634708,  1.1070959568, -0.0946228579,  0.0409227125, -0.8758629560,  0.4798634052,  0.2119475007,  0.1306757927, -0.5340384841, &
-0.5745104551,  1.3377038240,  0.0403960496,  0.1229517162, -0.1341982484, -1.2477325201,  0.4949547946, -0.6748173237,  0.2201293558, -0.1083113551, &
 2.1190633774,  0.2885525525 &
]
            layer3_weights(1:32, 32) = [ &
 0.1622547954,  0.5914255977,  0.1595398188, -0.0084923990,  0.0604768619, -0.0630656108,  0.0636243150, -0.1772074848,  0.4137883186,  0.5325356722, &
-0.2783259153,  0.0511917248, -0.0079889130, -0.0811709240,  0.2881321013, -0.4237937033, -0.5129061341,  0.3137625158, -0.2326724976,  0.2269518673, &
-0.1696681231,  0.0696845353,  0.2960090637,  0.0936460346, -0.5345003009,  0.6669621468, -0.1935370117,  0.1557581425, -0.2075888216, -0.3139259815, &
-0.2527952194,  0.1194226667 &
]


            output_weights(1:32, 1) = [ &
-0.0000000003,  0.0180202089,  0.1341764629, -0.1353849173,  0.1498290896,  0.0000160674, -0.0000045862,  0.0000000010,  0.1981988996,  0.0281018410, &
 0.0000001521, -0.0000002080, -0.0484959744,  0.0005065008,  0.1086519808, -0.0039222823, -0.0000000063, -0.0308670979,  0.0045845793,  0.0240991358, &
-0.0042588147, -0.0000000034,  0.1238537058,  0.0428183749,  0.0000000018, -0.0261663701,  0.1213537455,  0.0033072240, -0.1369564682, -0.0899980813, &
 0.0000004611,  0.0031690316 &
]
            output_weights(1:32, 2) = [ &
-0.0000023984, -1.2719044685,  0.0438882969, -0.0134323779, -0.0216248315, -0.0006815019,  0.0001058395, -0.0000002320,  0.0659501702,  1.5109313726, &
 0.0000011654,  0.0000024505,  0.0299263429,  0.0282827821,  0.0339169875,  0.6557381153, -0.0000028187,  1.0754861832,  0.3869624734, -0.0060578049, &
 0.5026500225,  0.0000006761, -0.0294807870, -0.0691563934, -0.0000000411, -0.3766768873,  0.0090813087, -0.3957533538, -0.0229023974, -0.0037480115, &
 0.0000004330,  0.0263328403 &
]
            output_weights(1:32, 3) = [ &
-0.0003530245,  0.2905428112,  2.9882926941,  5.2413377762,  3.5937590599,  14.6803960800,  11.9893035889, -0.0000230467,  4.8550090790, -2.8772861958, &
 0.0005043073, -0.0000024757, -7.8160347939,  0.6701589823, -2.0763285160, -11.6840429306, -0.0000531177,  2.7007896900,  2.8118889332,  6.0479578972, &
-5.2303509712,  0.0000516612,  3.8912594318,  5.9093728065, -0.0001330663, -4.4973649979,  4.2947611809, -12.8166236877, -1.8908137083,  3.8125798702, &
 0.0000905810,  4.5175008774 &
]

            layer1_biases(1:32) = [ &
 0.2720219493, -0.7045630813, -0.2463162094, -0.1382834166, -0.2801136076,  0.9262977839, -0.8820039630,  0.1357517242,  0.6530405283,  0.3692539930, &
 0.7082980871,  0.3914652765,  0.4658030272,  0.0778380260,  0.2024783343,  0.2469959855, -0.1926430613, -0.3997892141,  0.1560411006,  0.5708401203, &
-0.1586509049, -0.3218179047, -0.5668227673,  0.7053650022, -0.8694673777, -0.4529258907, -0.1197513938,  0.9465315938,  0.4658156335, -0.5882452726, &
 0.0244475547, -0.3088474870 &
]


            layer2_biases(1:32) = [ &
-0.0354203694, -0.2390508354, -0.2247524112,  0.1535077989, -0.1437761337,  0.2037659436,  0.0334711075,  0.1670102030,  0.3477884531,  0.4845680296, &
-0.2518903017, -0.1026945934, -0.0630717725, -0.0998486429,  0.1015944034, -0.2452375889, -0.0321421660,  0.0522569604,  0.0850484222, -0.3671129346, &
-0.2230990529, -0.0654209927,  0.0315741226, -0.1566601992, -0.0938975811, -0.0894358307, -0.1511701196, -0.0367191546,  0.0750010163, -0.1167084426, &
-0.1244883239,  0.2517487407 &
]


            layer3_biases(1:32) = [ &
 0.1804732531,  0.1256396472, -0.0076620881, -0.0818544552, -0.0473239869,  0.0703321919, -0.0458866358,  0.3844134808,  0.0635064989,  0.0473612435, &
 0.2481295019, -0.0113551700,  0.1092339605,  0.1596547663,  0.1184583083,  0.1601000577,  0.1982288510,  0.1414095610,  0.1568019092, -0.0859934986, &
 0.2111126631,  0.3282585442,  0.1591400653,  0.1016382501,  0.1139393747,  0.1672804803, -0.0400034152,  0.3166961670,  0.1905926168, -0.0897458717, &
 0.2542545497,  0.1957349628 &
]


            output_biases(1:3) = [ &
 0.1426522583, -0.0110503761, -4.9744253159 &
]

            layernorm1_weights(1:32) = [ &
 0.6649538279,  2.0541713238,  2.1491005421,  0.8052032590,  1.0225685835,  0.8813456893,  1.9329180717,  1.8058106899,  0.9229254723,  0.8993539214, &
 0.8548076153,  1.6398278475,  0.8828452229,  1.0713535547,  1.7351970673,  0.7510712147,  1.9249167442,  1.6007950306,  2.6997218132,  0.9792997837, &
 3.4353408813,  1.4416348934,  1.6110074520,  0.6025226712,  3.4457254410,  3.1445088387,  1.0597409010,  0.8872790933,  0.9594162107,  1.6790153980, &
 1.2609932423,  1.4987441301 &
]


            layernorm2_weights(1:32) = [ &
 1.1765676737,  2.4752430916,  2.3502805233,  1.1913324594,  1.0048236847,  1.3383135796,  1.1223877668,  0.9379837513,  1.3053568602,  1.2485356331, &
 1.3263971806,  0.9944991469,  1.6425759792,  8.1111764908,  0.9995996952,  1.1897863150,  1.6679366827,  0.9341684580,  1.2119307518,  1.2626227140, &
 1.1652692556,  1.4518045187,  1.2135065794,  3.8406546116,  1.4184551239,  3.0423500538,  1.3409875631,  2.8168244362,  1.1877775192,  1.4059569836, &
 3.0265421867,  1.1433925629 &
]


            layernorm3_weights(1:32) = [ &
-0.0000019436,  0.7701452971,  1.3761014938,  1.4621047974,  0.9424078465,  9.3690080643,  9.6874103546,  0.0000000094,  1.1300679445,  0.3265380263, &
-0.0000016597, -0.0000036077,  0.1469451636,  0.0442119576,  1.2270554304,  0.8722057939,  0.0000001992,  0.5891909599,  0.2892017365,  0.7635192871, &
 1.3535019159, -0.0000005988,  1.1668366194,  1.1982817650, -0.0000004525,  0.2262558341,  1.2480931282,  1.1240730286,  1.4505177736,  2.0856659412, &
 0.0000012138,  0.1380418092 &
]


            layernorm1_biases(1:32) = [ &
-0.4353129566, -0.0227727201, -0.6666002274, -0.2868893743, -0.2177617103, -0.5339375734, -0.6840897799, -0.3954317868, -0.7738291025,  0.1922760159, &
-0.7462793589,  0.5815809965, -0.5527347922, -0.0524994917, -0.6462769508, -0.1434885710, -0.4566187263, -0.6895244122, -0.3403850198, -0.4371877611, &
-0.6136326194, -0.0348989815,  0.0979606509, -0.4682917297, -0.6105647683, -0.4679475725, -0.5139066577, -0.6673679352, -0.0856153220,  0.0032281638, &
-0.4036709964, -0.1012281552 &
]


            layernorm2_biases(1:32) = [ &
-0.7219375372,  0.3592932224, -0.0222532470, -0.6128101945, -0.4953900874, -0.8070271611, -0.6288981438, -0.4983302355, -0.1457522362, -0.1074915230, &
-0.0522630699, -1.0209112167, -1.1511710882, -0.9565917253, -0.6527749896, -0.6043392420, -0.2842056155, -0.5259689689, -0.1426706016, -0.2660036683, &
-0.2818526328, -0.4937085807, -0.5261507630, -1.1400244236, -0.2692685127,  1.0358743668, -0.4281001091,  0.0419648066, -0.6255887151, -0.2678375244, &
-1.1150401831, -1.0392984152 &
]


            layernorm3_biases(1:32) = [ &
 0.0000013387, -0.0690332502, -0.4181568623,  0.2292515785, -0.3234014511,  0.4123012722, -1.0462418795,  0.0000000489, -0.0207506455,  0.0044428781, &
 0.0000004914, -0.0000012390, -0.0829806849, -0.0321669690, -0.1162038147, -0.0336314179,  0.0000000592, -0.1048946604, -0.2636145353,  0.0946406275, &
-0.2608875334,  0.0000018031, -0.4290182292, -0.2526172101,  0.0000003292, -0.5223908424, -0.0148703940, -0.1965416521, -0.1249809042,  0.3515452743, &
 0.0000002063, -0.1374239922 &
]


            ! Hoist the radius residual's scale out of the hot loop.  See its
            ! declaration for why this isn't a parameter.
            radius_scale_factor = 10.0d0**(2.0d0*real( RADIUS_LOG_MEAN, 8 ))

        end subroutine initialize_model

        ! Elementwise numerator/denominator with |denominator| floored at
        ! DIVIDE_FLOOR, sign preserved (an exactly zero denominator is treated
        ! as positive).  Guards the handful of divisions in
        ! analytic_baseline_step() whose denominator the closed form allows to
        ! reach zero.
        pure real*8 function safe_divide( numerator, denominator )

            implicit none

            real*8, intent(in) :: numerator, denominator

            safe_divide = numerator / sign( max( abs( denominator ), DIVIDE_FLOOR ), denominator )

        end function safe_divide

        ! log( 1 + x ), accurate for small x.  Fortran has no log1p intrinsic
        ! and the naive log( 1 + x ) loses the leading digits exactly where
        ! this is needed: analytic_baseline_step() takes a difference of two
        ! such logs that is O(1e-9) while each operand is O(0.1), and rho can
        ! itself be arbitrarily close to (or exactly) zero.
        pure real*8 function log1p_accurate( x )

            implicit none

            real*8, intent(in) :: x
            real*8             :: one_plus_x

            one_plus_x = 1.0d0 + x

            if (one_plus_x == 1.0d0) then
                log1p_accurate = x
            else
                log1p_accurate = log( one_plus_x )*x/(one_plus_x - 1.0d0)
            end if

        end function log1p_accurate

        ! Real cube root, including for negative arguments (Fortran's ** would
        ! return NaN for those).
        pure real*8 function cube_root( x )

            implicit none

            real*8, intent(in) :: x

            cube_root = sign( abs( x )**ONE_THIRD, x )

        end function cube_root

        ! Computes the droplet's most positive radius equilibrium -- the radius
        ! at which dydt()'s radius derivative vanishes -- for the supplied
        ! background conditions.  Mirrors physics.compute_radius_equilibria()
        ! as it is driven by
        ! QuadraticResidualnet_scaled_layernorm_eq_classifier_analytic._compute_normalized_equilibria().
        !
        ! Setting the radius derivative to zero reduces, after taking the log of
        ! both sides, to the cubic K*r^3 - B*r^2 + C = 0, which has no linear
        ! term and so depresses directly under x = 1/r into x^3 + p*x + q = 0
        ! with p = -B/C and q = K/C.
        !
        ! NOTE: The equilibrium is evaluated at Tp = Tf, matching
        !       _compute_normalized_equilibria(), which substitutes the air
        !       temperature for the droplet's own.  That premise (a droplet
        !       whose radius has settled has also equilibrated thermally)
        !       collapses K to exactly log( RH ) -- the einf/qinf terms cancel
        !       identically -- so none of the saturation vapor pressure
        !       machinery is needed here.
        !
        pure subroutine radius_equilibrium( air_temperature, rh, solute_term, &
                                            equilibrium_radius, has_equilibrium )

            implicit none

            real*8, intent(in)   :: air_temperature, rh, solute_term
            real*8, intent(out)  :: equilibrium_radius
            logical, intent(out) :: has_equilibrium

            real*8  :: b_coefficient, c_coefficient, p, q, discriminant
            real*8  :: sqrt_discriminant, magnitude, angle, cos_argument
            real*8  :: x_roots(3), largest_valid_x
            integer :: root_index, number_roots

            has_equilibrium    = .false.
            equilibrium_radius = 0.0d0

            ! Both would divide by zero (or take the log of a non-positive
            ! number) below.  Neither occurs for physical droplets.
            if (solute_term <= 0.0d0 .or. rh <= 0.0d0) return

            b_coefficient = KELVIN_COEFF/air_temperature
            c_coefficient = SOLUTE_COEFF*solute_term

            p = -b_coefficient/c_coefficient
            q = log( rh )/c_coefficient

            ! B and C are built from physical constants, the air temperature,
            ! and the solute term, none of which are negative, so p < 0 always
            ! and both closed forms below are valid.
            discriminant = (0.5d0*q)**2 + (p*ONE_THIRD)**3

            if (discriminant >= 0.0d0) then
                ! One real root: Cardano's formula.
                sqrt_discriminant = sqrt( discriminant )

                x_roots(1)   = cube_root( -0.5d0*q + sqrt_discriminant ) + &
                               cube_root( -0.5d0*q - sqrt_discriminant )
                number_roots = 1
            else
                ! Three real roots: the trigonometric method, valid here
                ! precisely because p < 0.
                magnitude    = 2.0d0*sqrt( -p*ONE_THIRD )
                cos_argument = min( max( -q/(2.0d0*sqrt( -(p*ONE_THIRD)**3 )), -1.0d0 ), 1.0d0 )
                angle        = acos( cos_argument )

                x_roots(1)   = magnitude*cos( angle*ONE_THIRD )
                x_roots(2)   = magnitude*cos( (angle + 2.0d0*PHYS_PI)*ONE_THIRD )
                x_roots(3)   = magnitude*cos( (angle + 4.0d0*PHYS_PI)*ONE_THIRD )
                number_roots = 3
            end if

            ! Back-substitute r = 1/x.  A root is a physically relevant
            ! equilibrium exactly when 0 < r < MAXIMUM_PHYSICAL_RADIUS, which
            ! in x is the single condition x > 1/MAXIMUM_PHYSICAL_RADIUS (this
            ! also excludes x = 0, i.e. the spurious r = +/-infinity root).
            !
            ! Of the (at most two) valid roots we want the STABLE one -- the
            ! radius the droplet actually relaxes toward, where d(dr/dt)/dr < 0.
            ! Writing the radius equation as f(r) = K*r^3 - B*r^2 + C, whose
            ! sign is the sign of dr/dt, f(0) = C > 0 and f rises to +infinity
            ! for K > 0, so when two positive roots exist the SMALLER is the
            ! stable equilibrium and the larger is the unstable critical
            ! (activation) radius, which a droplet never settles at.  In
            ! x = 1/r that makes the stable root the LARGEST valid x.
            !
            ! NOTE: The reference takes the most positive *radius* here, i.e.
            !       the critical radius, which is wrong whenever two roots
            !       exist (~0.2% of droplets overall, but ~33% of those with
            !       RH within 0.1% of saturation).  It is spectacularly wrong
            !       near saturation, where the critical radius ~ B/log( RH )
            !       diverges -- an RH of 1.000003 puts it at 341 microns.
            largest_valid_x = 0.0d0

            do root_index = 1, number_roots
                if (x_roots(root_index) > INV_MAXIMUM_PHYSICAL_RADIUS .and. &
                    x_roots(root_index) > largest_valid_x) then
                    largest_valid_x = x_roots(root_index)
                end if
            end do

            if (largest_valid_x > 0.0d0) then
                equilibrium_radius = 1.0d0/largest_valid_x
                has_equilibrium    = .true.
            end if

        end subroutine radius_equilibrium

        ! Advances a droplet one timestep with the closed-form analytic
        ! baseline the network regresses a correction to.  Mirrors
        ! QuadraticResidualnet_scaled_layernorm_eq_classifier_analytic._analytic_baseline_step()
        ! (itself a port of physics.approximate_droplet_step()) line for line;
        ! any change made there must be mirrored here.
        !
        ! Two baselines are blended with a sigmoid in log10( r ):
        !
        !   large droplet - dydt()'s temperature equation is Taylor expanded in
        !                   Tp about Tp0 with the radius frozen, giving a
        !                   closed form for both r and Tp over the step.
        !   wet bulb      - Tp is pinned to the temperature at which dydt()'s
        !                   temperature derivative vanishes and the radius is
        !                   stepped with the curvature and solute terms dropped
        !                   from the saturation exponent, which removes all
        !                   r dependence from the rate so integrating over the
        !                   step is just a multiply by delta_t.
        !
        pure subroutine analytic_baseline_step( input_radius, particle_temperature, solute_term, &
                                                air_temperature, rh, rhoa, delta_t, &
                                                baseline_radius, baseline_temperature )

            implicit none

            real*8, intent(in)  :: input_radius, particle_temperature, solute_term
            real*8, intent(in)  :: air_temperature, rh, rhoa, delta_t
            real*8, intent(out) :: baseline_radius, baseline_temperature

            real*8 :: r0, r0_squared, einf, gamma_coefficient
            real*8 :: t1, t2, t3, exponent_mu, exp_t3_mu, eta, deta_dtp
            real*8 :: a, b, c, alpha, u, v, w, k, q, x2, rho
            real*8 :: tau, k_tau, decay, ttilde, log_term, ttilde_integral
            real*8 :: delta_r2, r2_stepped, output_radius, output_temperature
            real*8 :: a_wb, w_wb, g_wb, e_wb, exponent_wb, t_wb_denominator, t_wb
            real*8 :: qinf, t1_wb, qstar_reduced, dr2dt_reduced, r2_stepped_2
            real*8 :: output_2_radius, output_2_temperature, weight_large

            ! Droplet radii are always positive in distribution; this only
            ! keeps an out-of-distribution r <= 0 out of the divisions below.
            r0         = max( input_radius, MIN_RADIUS )
            r0_squared = r0*r0

            ! ---- large-droplet baseline ---------------------------------
            !
            ! Taylor coefficients of g(Ttilde) := dr^2/dt about Tp0 with the
            ! radius frozen: g ~ a*Ttilde^2 + b*Ttilde + c.
            einf              = 610.94d0*exp( (17.6257d0*(air_temperature - 273.15d0)) / &
                                              (243.04d0 + (air_temperature - 273.15d0)) )
            gamma_coefficient = GAMMA_COEFF*einf

            t1 = LV_MW_RU*(1.0d0/air_temperature - 1.0d0/particle_temperature)
            t2 = KELVIN_COEFF/(r0*particle_temperature)
            t3 = -SOLUTE_COEFF*solute_term/(r0*r0_squared)

            ! The reference forms exp( t3 ) and mu = exp( t1 + t2 )/Tp0
            ! separately, but they only ever appear multiplied together, so the
            ! exponents are summed first and exponentiated once.  This is
            ! mathematically identical while being both cheaper (one exp rather
            ! than two) and better behaved: t2 grows as 1/r and t3 falls as
            ! -1/r^3, so for a sufficiently small radius the reference's
            ! exp( t1 + t2 ) overflows to infinity while its exp( t3 )
            ! underflows to zero, and their product is 0*infinity = NaN.  Summed
            ! first, t3 dominates and the product correctly goes to zero.
            !
            ! NOTE: exp_t3_mu still underflows to exactly zero for small, salty
            !       droplets, which is what drives u to exactly zero in the log
            !       term below -- that behavior is preserved, and short
            !       circuited rather than computed (~20% of droplets).
            exponent_mu = t1 + t2 + t3

            if (exponent_mu < MINIMUM_EXP_ARGUMENT) then
                exp_t3_mu = 0.0d0
            else
                exp_t3_mu = exp( exponent_mu )/particle_temperature
            end if

            eta      = LV_MW_RU/(particle_temperature*particle_temperature) - &
                       (t2 + 1.0d0)/particle_temperature
            deta_dtp = -2.0d0*LV_MW_RU/(particle_temperature*particle_temperature*particle_temperature) + &
                       (2.0d0*t2 + 1.0d0)/(particle_temperature*particle_temperature)

            c = gamma_coefficient*(rh/air_temperature - exp_t3_mu)
            b = -gamma_coefficient*exp_t3_mu*eta
            a = -0.5d0*gamma_coefficient*exp_t3_mu*(eta*eta + deta_dtp)

            ! Quadratic coefficients of dTp/dt = (u*Ttilde^2 + v*Ttilde + w)/r0^2.
            alpha = ALPHA_COEFF*rhoa

            u = a*BETA
            v = BETA*b + alpha
            w = alpha*(particle_temperature - air_temperature) + BETA*c

            ! Roots via the cancellation-safe quadratic form.  x2 = w/q is the
            ! stable equilibrium Ttilde relaxes toward; rho = x2/x1 stays
            ! finite as u -> 0.  The radicand is clamped rather than left to
            ! go negative out of distribution.
            k = sqrt( max( v*v - 4.0d0*u*w, 0.0d0 ) )

            ! sign( k, v ) would return +k for v == 0, where the reference
            ! takes sign( 0 )*k = 0; spelled out so the two agree exactly.
            if (v > 0.0d0) then
                q = -0.5d0*(v + k)
            else if (v < 0.0d0) then
                q = -0.5d0*(v - k)
            else
                q = 0.0d0
            end if

            x2  = safe_divide( w, q )
            rho = safe_divide( u*x2, q )

            ! Closed-form temperature offset.  exp( -k*tau ) underflows
            ! harmlessly to zero for steps much longer than the thermal
            ! relaxation time.
            tau   = delta_t/r0_squared
            k_tau = k*tau

            ! Short circuited for steps much longer than the thermal relaxation
            ! time, where exp() underflows to exactly zero anyway (~52% of
            ! droplets) -- see MINIMUM_EXP_ARGUMENT.
            if (k_tau > -MINIMUM_EXP_ARGUMENT) then
                decay = 0.0d0
            else
                decay = exp( -k_tau )
            end if

            ttilde = safe_divide( x2*(decay - 1.0d0), rho*decay - 1.0d0 )

            ! int_0^tau Ttilde dtau'.  The log difference is O(u), so dividing
            ! by u is well conditioned even where u is tiny -- both shrink
            ! together and double precision resolves the ratio directly.  Only
            ! u being *exactly* zero (a genuine removable singularity, and
            ! common here: exp( t3 ) underflowing drives a, and so u, to zero
            ! for roughly a fifth of in-distribution droplets) needs the
            ! separate limit form.
            if (u == 0.0d0) then
                log_term = safe_divide( x2, q )*(1.0d0 - decay)
            else if (decay == 0.0d0) then
                ! log1p( -rho*decay ) is log1p( 0 ), i.e. exactly zero, so the
                ! first of the two logarithms is skipped rather than computed.
                ! Bit-for-bit identical to the general case below.
                log_term = safe_divide( -log1p_accurate( max( -rho, -1.0d0 + 1.0d-12 ) ), u )
            else
                log_term = safe_divide( log1p_accurate( max( -rho*decay, -1.0d0 + 1.0d-12 ) ) - &
                                        log1p_accurate( max( -rho,       -1.0d0 + 1.0d-12 ) ), u )
            end if

            ttilde_integral = x2*tau - log_term

            ! Energy-balance identity integrated over the step:
            !   beta*delta( r^2 ) = r0^2*delta( Tp ) - alpha*int (Tp - Tf) dt
            delta_r2   = (r0_squared*ttilde - &
                          alpha*(r0_squared*ttilde_integral + &
                                 (particle_temperature - air_temperature)*delta_t))*INV_BETA
            r2_stepped = max( r0_squared + delta_r2, 0.0d0 )

            output_radius      = sqrt( r2_stepped )
            output_temperature = particle_temperature + ttilde

            ! ---- wet-bulb baseline --------------------------------------
            !
            ! T_wb( r0 ): the temperature at which dydt()'s temperature
            ! derivative vanishes, linearized about Tp = Tf.
            !
            ! NOTE: The reference pins the solute (Raoult) term of this branch
            !       to zero, so its contribution to the exponent below is
            !       dropped here rather than computed and multiplied by zero.
            !       Restore it if the reference ever re-enables it.
            !
            a_wb = KELVIN_COEFF
            w_wb = LV_MW_RU - air_temperature
            g_wb = G_WB_COEFF*rhoa*air_temperature*air_temperature*air_temperature/einf

            exponent_wb = a_wb/(air_temperature*r0)

            if (exponent_wb > MAXIMUM_EXP_ARGUMENT) then
                ! r0 -> 0 limit.  exp() would overflow to infinity here and the
                ! ratio below would evaluate to infinity/infinity, i.e. NaN (as
                ! it does in the reference).  Taking the limit analytically
                ! instead, the Kelvin term dominates the denominator and
                ! T_wb -> Tf.  Only reachable for radii orders of magnitude
                ! below the trained range -- the exponent is ~113 at the
                ! smallest radius the model was trained on -- so this never
                ! engages for a physically meaningful droplet, it just keeps a
                ! garbage input from poisoning the caller with a NaN.
                t_wb = air_temperature
            else
                e_wb = exp( exponent_wb )

                t_wb_denominator = g_wb + (w_wb - a_wb/r0)*e_wb
                t_wb             = air_temperature - air_temperature*air_temperature* &
                                   safe_divide( e_wb - rh, t_wb_denominator )
            end if

            ! d(r^2)/dt at Tp = T_wb with the curvature and solute terms
            ! dropped from the saturation exponent, so the rate is r
            ! independent and the step is a plain multiply by delta_t.
            qinf          = rh/rhoa*(einf*MW_RU/air_temperature)
            t1_wb         = LV_MW_RU*(1.0d0/air_temperature - 1.0d0/t_wb)
            qstar_reduced = einf*MW_RU/t_wb/rhoa*exp( t1_wb )

            dr2dt_reduced = DR2DT_COEFF*rhoa*(qinf - qstar_reduced)

            r2_stepped_2 = max( r0_squared + dr2dt_reduced*delta_t, 0.0d0 )

            output_2_radius      = sqrt( r2_stepped_2 )
            output_2_temperature = t_wb

            ! ---- blend --------------------------------------------------
            ! Sigmoid in log10( r0 ): the large-droplet branch dominates for
            ! large droplets, the wet-bulb branch takes over for small ones.
            weight_large = 1.0d0/(1.0d0 + exp( -(log10( r0 ) - BLEND_LOG_RADIUS_CENTER)*INV_BLEND_LOG_RADIUS_WIDTH ))

            baseline_radius      = weight_large*output_radius + (1.0d0 - weight_large)*output_2_radius
            baseline_temperature = weight_large*output_temperature + (1.0d0 - weight_large)*output_2_temperature

        end subroutine analytic_baseline_step

        ! Estimates a droplet's future size and temperature based on it's current size
        ! and temperature, as well as key parameters from the environment its in.
        ! Inputs and outputs are provided/returned in un-normalized physical scales.
        subroutine estimate( input, output )

            implicit none

            !
            ! NOTE: This is hardcoded to assume a batch size of 1 so we can have
            !       a 1D array vs dealing with a 2D array with a singleton
            !       dimension.
            !
            real*4, dimension(NUMBER_INPUTS), intent(in)   :: input
            real*4, dimension(NUMBER_OUTPUTS), intent(out) :: output

            real*4, dimension(NUMBER_INPUTS)               :: normalized_input
            integer                                        :: output_index

            ! Accumulator for intermediate layer's mean and standard deviation to
            ! implement layer norm.
            real*4                                         :: layer_sum      = 0.0
            real*4                                         :: layer_variance = 0.0

            ! Equilibrium classification and the analytic baseline the
            ! network's regression is a correction to.
            real*4  :: classifier_probability
            real*8  :: equilibrium_radius, baseline_radius, baseline_temperature
            real*8  :: guard_radius, quadratic_change
            real*8  :: quadratic_radius
            logical :: has_equilibrium, use_equilibrium


            ! Normalize the inputs so they're in the range [-1, 1].
            normalized_input(RADIUS_INDEX)          = (log10( input(RADIUS_INDEX) ) - RADIUS_LOG_MEAN) / RADIUS_LOG_WIDTH
            normalized_input(TEMPERATURE_INDEX)     = (input(TEMPERATURE_INDEX) - TEMPERATURE_MEAN) / TEMPERATURE_WIDTH
            normalized_input(SALT_SOLUTE_INDEX)     = (log10( input(SALT_SOLUTE_INDEX) ) - SALT_SOLUTE_LOG_MEAN) / SALT_SOLUTE_LOG_WIDTH
            normalized_input(AIR_TEMPERATURE_INDEX) = (input(AIR_TEMPERATURE_INDEX) - AIR_TEMPERATURE_MEAN) / AIR_TEMPERATURE_WIDTH
            normalized_input(RH_INDEX)              = (input(RH_INDEX) - RH_MEAN) / RH_WIDTH
            normalized_input(RHOA_INDEX)            = (input(RHOA_INDEX) - RHOA_MEAN) / RHOA_WIDTH

            ! The integration time is normalized linearly -- see TIME_RANGE.
            normalized_input(TFINAL_INDEX)          = (input(TFINAL_INDEX) - TIME_MEAN) / TIME_WIDTH

            ! Compute x_1 = W_1*I + b_1 and accumulate this layer's sum.
            layer_sum      = real( 0.0, kind=4 )
            layer_variance = real( 0.0, kind=4 )

            do output_index = 1, NUMBER_HIDDEN_LAYER1_NEURONS
                layer1_intermediate(output_index) = &
                     sum( normalized_input(:) * layer1_weights(:, output_index) ) + layer1_biases(output_index)
                layer_sum                         = layer_sum + layer1_intermediate(output_index)

            end do

            layer_sum = layer_sum / NUMBER_HIDDEN_LAYER1_NEURONS

            do output_index = 1, NUMBER_HIDDEN_LAYER1_NEURONS
                layer_variance = layer_variance + (layer1_intermediate(output_index) - layer_sum)**2
            end do
            ! NOTE: The epsilon goes inside the square root, matching
            !       PyTorch's (x - mean)/sqrt( var + eps ).
            layer_variance = sqrt( layer_variance / NUMBER_HIDDEN_LAYER1_NEURONS + LAYERNORM_EPSILON )

            ! Compute x_1 = SiLU( x_1 ) and fused layernorm.
            do output_index = 1, NUMBER_HIDDEN_LAYER1_NEURONS
                layer1_intermediate(output_index) = &
                    (layer1_intermediate(output_index) - layer_sum) / layer_variance &
                      * layernorm1_weights(output_index) + layernorm1_biases(output_index)

                layer1_intermediate(output_index) = &
                     layer1_intermediate(output_index) / (real( 1.0, kind=4 ) + &
                                                          exp( real( -1.0, kind=4 ) * layer1_intermediate(output_index) ))
            end do

            ! Compute x_2 = W_2*x_1 + b_2 and accumulate this layer's sum.
            layer_sum      = real( 0.0, kind=4 )
            layer_variance = real( 0.0, kind=4 )

            do output_index = 1, NUMBER_HIDDEN_LAYER2_NEURONS
                layer2_intermediate(output_index) = &
                     sum( layer1_intermediate(:) * layer2_weights(:, output_index) ) + layer2_biases(output_index)

                layer_sum                         = layer_sum + layer2_intermediate(output_index)

            end do

            layer_sum = layer_sum / NUMBER_HIDDEN_LAYER2_NEURONS

            do output_index = 1, NUMBER_HIDDEN_LAYER2_NEURONS
                layer_variance = layer_variance + (layer2_intermediate(output_index) - layer_sum)**2
            end do
            ! NOTE: The epsilon goes inside the square root, matching
            !       PyTorch's (x - mean)/sqrt( var + eps ).
            layer_variance = sqrt( layer_variance / NUMBER_HIDDEN_LAYER2_NEURONS + LAYERNORM_EPSILON )

            ! Compute x_2 = SiLU( x_2 ) and fused layernorm.
            do output_index = 1, NUMBER_HIDDEN_LAYER2_NEURONS
                layer2_intermediate(output_index) = &
                    (layer2_intermediate(output_index) - layer_sum) / layer_variance &
                      * layernorm2_weights(output_index) + layernorm2_biases(output_index)

                layer2_intermediate(output_index) = &
                     layer2_intermediate(output_index) / (real( 1.0, kind=4 ) + &
                                                          exp( real( -1.0, kind=4 ) * layer2_intermediate(output_index) ))
            end do

            ! Compute x_3 = W_3*x_2 + b_3 and accumulate this layer's sum.
            layer_sum      = real( 0.0, kind=4 )
            layer_variance = real( 0.0, kind=4 )

            do output_index = 1, NUMBER_HIDDEN_LAYER3_NEURONS
                layer3_intermediate(output_index) = &
                     sum( layer2_intermediate(:) * layer3_weights(:, output_index) ) + layer3_biases(output_index)

                layer_sum                         = layer_sum + layer3_intermediate(output_index)

            end do

            layer_sum = layer_sum / NUMBER_HIDDEN_LAYER3_NEURONS

            do output_index = 1, NUMBER_HIDDEN_LAYER3_NEURONS
                layer_variance = layer_variance + (layer3_intermediate(output_index) - layer_sum)**2
            end do
            ! NOTE: The epsilon goes inside the square root, matching
            !       PyTorch's (x - mean)/sqrt( var + eps ).
            layer_variance = sqrt( layer_variance / NUMBER_HIDDEN_LAYER3_NEURONS + LAYERNORM_EPSILON )

            ! Compute x_3 = SiLU( x_3 ) and fused layernorm.
            do output_index = 1, NUMBER_HIDDEN_LAYER3_NEURONS
                layer3_intermediate(output_index) = &
                    (layer3_intermediate(output_index) - layer_sum) / layer_variance &
                      * layernorm3_weights(output_index) + layernorm3_biases(output_index)

                layer3_intermediate(output_index) = &
                     layer3_intermediate(output_index) / (real( 1.0, kind=4 ) + &
                                                          exp( real( -1.0, kind=4 ) * layer3_intermediate(output_index) ))
            end do

            ! Compute O = W_4*x_3 + b_4.
            do output_index = 1, NUMBER_OUTPUTS
                output(output_index) = sum( layer3_intermediate(:) * output_weights(:, output_index) ) + output_biases(output_index)
            end do

            ! Zero out corrections below the deadband -- see RESIDUAL_DEADBAND.
            if (abs( output(RADIUS_INDEX) ) < RESIDUAL_DEADBAND) then
                output(RADIUS_INDEX) = real( 0.0, kind=4 )
            end if

            if (abs( output(TEMPERATURE_INDEX) ) < RESIDUAL_DEADBAND) then
                output(TEMPERATURE_INDEX) = real( 0.0, kind=4 )
            end if

            ! Activate the equilibrium classifier neuron.  This is reported back
            ! to the caller in the third output slot; only the radius and
            ! temperature are needed to advance a droplet.
            classifier_probability = 1.0 / (1.0 + exp( -output(3) ))
            output(3)              = classifier_probability

            ! Droplets the classifier flags, and which actually have a physics
            ! equilibrium, defer to that equilibrium entirely rather than to the
            ! network's regression.
            !
            ! NOTE: The reference expresses this as the radius residual that
            !       would reconstruct the equilibrium once the baseline is added
            !       back, then reconstructs it.  That round trip is an exact
            !       algebraic identity, so the equilibrium radius (and the air
            !       temperature it pairs with) is used directly here -- which
            !       also means the analytic baseline never has to be evaluated
            !       for these droplets.
            !
            use_equilibrium = .false.

            if (classifier_probability > EQUILIBRIUM_PROBABILITY_THRESHOLD) then
                call radius_equilibrium( real( input(AIR_TEMPERATURE_INDEX), 8 ), &
                                         real( input(RH_INDEX), 8 ), &
                                         real( input(SALT_SOLUTE_INDEX), 8 ), &
                                         equilibrium_radius, has_equilibrium )

                if (has_equilibrium) then
                    ! Reject an equilibrium the droplet could not reach within
                    ! this step -- see EQUILIBRIUM_JUMP_RATE_BUDGET.  The input
                    ! radius is floored the same way analytic_baseline_step()
                    ! floors it so an out-of-distribution r <= 0 cannot invert
                    ! the test.
                    guard_radius = max( real( input(RADIUS_INDEX), 8 ), MIN_RADIUS )

                    quadratic_change = equilibrium_radius*equilibrium_radius - &
                                       guard_radius*guard_radius

                    use_equilibrium = (abs( quadratic_change ) <= &
                                       EQUILIBRIUM_JUMP_RATE_BUDGET*real( input(TFINAL_INDEX), 8 )) .and. &
                                      (-quadratic_change <= EQUILIBRIUM_MAX_QUADRATIC_DROP)
                end if
            end if

            if (use_equilibrium) then
                output(RADIUS_INDEX)      = real( equilibrium_radius, 4 )
                output(TEMPERATURE_INDEX) = input(AIR_TEMPERATURE_INDEX)
            else
                ! The network regresses a correction to the analytic baseline
                ! rather than the stepped radius/temperature themselves, so the
                ! baseline is what its outputs are anchored to.
                call analytic_baseline_step( real( input(RADIUS_INDEX), 8 ), &
                                             real( input(TEMPERATURE_INDEX), 8 ), &
                                             real( input(SALT_SOLUTE_INDEX), 8 ), &
                                             real( input(AIR_TEMPERATURE_INDEX), 8 ), &
                                             real( input(RH_INDEX), 8 ), &
                                             real( input(RHOA_INDEX), 8 ), &
                                             real( input(TFINAL_INDEX), 8 ), &
                                             baseline_radius, baseline_temperature )

                ! Add the regressed quadratic (r^2) residual to the baseline and
                ! convert back to a radius.  Floored since the baseline radius
                ! can legitimately be exactly zero -- see MIN_QUADRATIC_RADIUS.

                quadratic_radius = max( baseline_radius*baseline_radius + &
                                        real( output(RADIUS_INDEX), 8 )*radius_scale_factor, &
                                        MIN_QUADRATIC_RADIUS )

                output(RADIUS_INDEX) = real( sqrt( quadratic_radius ), 4 )

                ! The temperature residual is anchored to the baseline's
                ! temperature.  Denormalizing the sum of the regressed residual
                ! and the normalized baseline temperature,
                !
                !   (residual + (T_base - T_mean)/T_width)*T_width + T_mean
                !
                ! collapses to the form below, which avoids normalizing the
                ! baseline temperature only to immediately undo it.
                output(TEMPERATURE_INDEX) = output(TEMPERATURE_INDEX)*TEMPERATURE_WIDTH + &
                                            real( baseline_temperature, 8 )
            end if

            end subroutine estimate
end module droplet_model
