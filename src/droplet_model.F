!
! NOTE: This module was generated from wily-fatima on 2026/08/31 at 13:56:21.
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
 "wily-fatima (2026/08/31 at 13:56:21)"

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
    real*4, parameter :: RADIUS_LOG_RANGE(2)      = [-8.000, -4.250]
    real*4, parameter :: TEMPERATURE_RANGE(2)     = [278.0, 300.0]
    real*4, parameter :: SALT_SOLUTE_LOG_RANGE(2) = [-20.25, -11.00]
    real*4, parameter :: AIR_TEMPERATURE_RANGE(2) = [278.00, 300.00]
    real*4, parameter :: RH_RANGE(2)              = [0.50, 1.04]
    real*4, parameter :: RHOA_RANGE(2)            = [1.14, 1.24]

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
    real*4, parameter :: TIME_LOG_RANGE(2) = [-2.100, -1.500]
    real*4, parameter :: TIME_RANGE(2)     = [7.9432823e-3, 3.1622777e-2]

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
    real*8, parameter :: INV_BLEND_LOG_RADIUS_WIDTH  = 1.0d0/0.25d0

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
-0.0639066547, -0.5811567903,  0.0375013202,  0.3832122982, -0.1599815935,  0.0186308268,  0.3080662489 &
]
            layer1_weights(1:7, 2) = [ &
-0.6852196455, -0.0329331942, -1.2913724184, -0.1843103766, -0.0300531033,  0.0069523193, -0.0267554354 &
]
            layer1_weights(1:7, 3) = [ &
 1.3727551699,  0.4859090149, -0.1827682853, -0.5330384374, -0.0639131069, -0.0050902166,  0.0048174816 &
]
            layer1_weights(1:7, 4) = [ &
-1.3830294609,  0.0531113259, -0.2520403862, -0.0606120303,  0.7252767682, -0.0017943907,  0.1384443343 &
]
            layer1_weights(1:7, 5) = [ &
 0.3900920749, -0.0285721757, -0.2664812505, -0.5672764182, -0.4119651616,  0.0132536916, -0.0696507245 &
]
            layer1_weights(1:7, 6) = [ &
-1.3847689629, -0.2062228322, -0.3806796670,  0.5499436259, -0.8890195489,  0.0027951044,  0.6676599383 &
]
            layer1_weights(1:7, 7) = [ &
-0.2564625740,  0.0555126257, -0.5375051498, -0.0630575716, -0.4572459757, -0.0113415951, -0.3093244433 &
]
            layer1_weights(1:7, 8) = [ &
-0.5722388625,  0.0812486112, -0.3096376359,  0.3045417964,  0.7051139474, -0.0293511972,  0.0605296306 &
]
            layer1_weights(1:7, 9) = [ &
-1.3298125267, -0.2397170067, -0.8727605343,  0.3961469233, -0.9365757108, -0.0043830290,  0.2591870427 &
]
            layer1_weights(1:7, 10) = [ &
-0.3498828113,  0.0847027302, -0.1251785606, -0.0903067663,  0.6211461425,  0.0023677719,  0.2312525809 &
]
            layer1_weights(1:7, 11) = [ &
 0.5278348923,  0.5499497056, -0.4349372387, -0.8591850400, -0.4716270566,  0.0222379602,  0.5969047546 &
]
            layer1_weights(1:7, 12) = [ &
 2.6424493790,  0.0162450988, -0.1784915477, -0.1110898927, -0.0399516560, -0.0106528196, -0.0891681388 &
]
            layer1_weights(1:7, 13) = [ &
-1.0466103554,  0.0303860512,  1.0709195137, -0.0754725635,  0.0023018988, -0.0060394751,  0.0249128249 &
]
            layer1_weights(1:7, 14) = [ &
-1.3801255226,  0.0062322794,  0.1203284562, -0.0074382517, -0.5163483620,  0.0010162030,  0.1526401639 &
]
            layer1_weights(1:7, 15) = [ &
 0.4450323284, -0.2721033096, -0.7063614130,  0.2702661455, -0.0032069273,  0.0148502328,  0.4735203981 &
]
            layer1_weights(1:7, 16) = [ &
 0.7163007259,  0.0982757062, -0.0709396452,  0.1373101771, -0.1501650065, -0.0052146325,  0.1377008855 &
]
            layer1_weights(1:7, 17) = [ &
-1.1251006126,  0.0429972894, -0.8060941696,  0.0848093778, -0.2088675946, -0.0151858861,  0.1007566005 &
]
            layer1_weights(1:7, 18) = [ &
-1.2591747046,  0.0312213562,  1.3831011057, -0.0902219489, -0.0016835427, -0.0019252180,  0.0812367573 &
]
            layer1_weights(1:7, 19) = [ &
 0.8903892636,  0.0573884547, -0.1164732352, -0.1661632657,  0.2622758150, -0.0062502893, -0.0479862504 &
]
            layer1_weights(1:7, 20) = [ &
 0.9880213141,  0.0642661601, -0.1124483198, -0.2322110087,  0.5547456741, -0.0053191353, -0.6549947262 &
]
            layer1_weights(1:7, 21) = [ &
-0.7552003860,  0.0758960396,  0.8702223897,  0.0416164808, -0.4931664765, -0.0072659226,  0.1047527790 &
]
            layer1_weights(1:7, 22) = [ &
 0.2970216572,  0.1371683329, -0.3351857960, -0.2563644052, -0.0558092408, -0.1273474097,  0.0952332392 &
]
            layer1_weights(1:7, 23) = [ &
 1.2376811504, -0.0083660567, -0.3696132600, -0.0280537792,  0.7104604244, -0.0072989454,  0.1272643805 &
]
            layer1_weights(1:7, 24) = [ &
 1.7521072626,  0.0282607339, -0.1389368922, -0.0694633871, -0.4081214964, -0.0026751554,  0.1684044152 &
]
            layer1_weights(1:7, 25) = [ &
 1.7119135857, -0.0135557167, -0.4233708680, -0.0408132263, -0.2175906897, -0.0089691384, -0.4354458451 &
]
            layer1_weights(1:7, 26) = [ &
-1.6730476618,  0.6175554991, -0.4066402316, -0.5078814030, -0.6054698825,  0.0007170878,  0.3436461687 &
]
            layer1_weights(1:7, 27) = [ &
 0.4952802658, -0.0060794805, -0.4855622649,  0.6186575890, -0.5012131929, -0.0344661735,  0.0688349009 &
]
            layer1_weights(1:7, 28) = [ &
 1.4210637808, -0.2097571045, -0.1303963363,  0.1905952543,  0.0065273624, -0.0093261572,  0.0212605260 &
]
            layer1_weights(1:7, 29) = [ &
 0.1908008307,  0.0474293195, -0.2062111795, -0.0173671059, -0.2345447689, -0.0028356453, -1.0084564686 &
]
            layer1_weights(1:7, 30) = [ &
-1.4084734917,  0.0071964627,  0.9609581828,  0.0381837636, -0.0449563265, -0.0081675369,  0.0372899659 &
]
            layer1_weights(1:7, 31) = [ &
 0.2992296517, -0.3974486589, -0.2162490636,  0.4018757045,  0.2502427399, -0.0079559684,  0.0570197366 &
]
            layer1_weights(1:7, 32) = [ &
 0.1910721511,  0.1247930378, -0.1408784837, -0.6061973572,  0.2246414721,  0.0077894297, -0.0638399795 &
]


            layer2_weights(1:32, 1) = [ &
 1.0640175343,  0.7797927856,  1.0707491636, -1.0474276543,  0.4683467150,  0.2791891992,  1.0447551012,  0.7047392726,  0.9615682364,  0.0159212574, &
 1.0531632900,  0.6947719455,  0.1755181104, -0.1620624810, -0.4993708432,  0.9482868910,  1.0823245049, -1.2715697289, -1.0099964142,  0.3104067147, &
 0.1048211679,  0.8966270089,  0.2456314117, -1.4678783417, -0.7006230354, -0.4687922299, -1.1265006065, -0.5140022635,  0.9268728495, -0.7752827406, &
-0.6344933510, -1.1820945740 &
]
            layer2_weights(1:32, 2) = [ &
-1.6131961346,  0.3500309289,  1.6865853071,  0.2390123159, -0.5004805923,  0.2917120457,  0.5169925690,  0.5759269595,  0.2365900129,  0.3947419822, &
 1.6192815304, -0.2210395783, -0.4524113536, -0.3532151878, -0.6481185555,  0.7088285685,  0.6298498511, -0.3795252442,  0.9123020768, -0.0416063257, &
 0.0146307461,  0.1715409756,  0.1803975701,  0.5714634061, -0.0365194678, -0.8728098273, -0.1854044795, -1.1571091413,  0.3535060585,  0.3232130110, &
 0.3976928890,  0.8368397355 &
]
            layer2_weights(1:32, 3) = [ &
-0.6477740407,  0.0895256698,  0.7216358781,  0.3532347381, -0.5642109513,  0.4558241963,  0.0416320860, -0.1292329282, -0.0827824250,  0.2678154409, &
 0.2539075613,  0.1786435694, -0.6211568713, -0.8807254434, -0.0922574773, -0.0481108911, -0.3163864911, -0.8199080229,  0.2946658731, -0.2046505958, &
 0.0955553204,  0.6079048514, -0.1700465083,  0.8452050090,  0.3292264342, -0.6828333139,  0.6750448942, -0.2765017450, -0.0822963789, -0.8249114156, &
-0.3540568650, -0.8478258252 &
]
            layer2_weights(1:32, 4) = [ &
 0.0626045540,  0.5393325090,  0.9694742560,  0.1402936429,  0.1487738788,  0.8971590400,  0.6652498841,  0.8583669066,  1.0007827282, -0.7229731083, &
 0.7111296058,  0.1429691613, -0.3277480602,  0.3402925432,  0.3693431020,  0.3076741993, -1.0170543194, -1.0049413443,  0.6409693360, -0.3187731504, &
 0.5083422065, -0.1995999962,  0.5962343812, -0.2941268981, -0.0838505998,  0.0230287742,  0.1323773116, -0.4074852765, -0.3462114334, -0.9744706750, &
-0.3465726078,  1.5435637236 &
]
            layer2_weights(1:32, 5) = [ &
 0.1609050333, -1.1170001030, -0.3242490292, -0.4732633233, -0.0240374599,  0.6044027805,  0.0393610671,  0.1070964113, -0.2188327312, -0.0475789309, &
 0.1932804286, -0.5064530373, -0.1239462495,  0.3355064094, -0.1954969764,  0.0149642034,  0.2837002575,  0.6787111759,  0.1560617238, -0.0711586997, &
 0.7359970808,  0.0780459493, -0.0141601898, -0.7749599814, -0.3234105408,  0.1036907732, -0.4168922603, -0.6053515077, -0.2514743209,  0.7259529233, &
 0.0391876586,  0.3583758771 &
]
            layer2_weights(1:32, 6) = [ &
 0.0456471555, -0.6663008332,  0.0230697952, -1.1131989956, -0.3408647478, -1.4097427130,  0.4009971321, -0.9286563396,  0.0247164294, -0.9862995148, &
-0.3252352476,  0.7087677121,  0.2087461948, -0.0531180315, -0.0014924828,  0.7055673003,  0.6377986670,  0.2797811627,  0.4448342621, -0.2272836119, &
-0.6461126208, -0.0497438498,  0.2717279792,  0.9346234798,  0.2560229599, -0.6707813740,  0.1673338264, -0.0571400113,  0.5117536783, -0.1927329898, &
-0.5386350155, -0.6500449777 &
]
            layer2_weights(1:32, 7) = [ &
 1.0419883728,  0.0535507239, -1.4963462353, -0.4209512472, -0.2605403364, -0.1239044666,  0.8072006106,  0.0098736668,  0.4781907499, -0.8590705991, &
 0.4340974689,  0.2517650127, -0.5904898643, -0.4865851700,  0.5504146218,  0.5702266693,  0.5968366265,  0.1779152453,  0.0976088420, -0.1857659072, &
-0.3081197739,  0.4130647480,  0.3545035720,  0.0089690601,  0.4769211709,  0.9749743938,  0.0889543146,  1.1489543915,  0.0524533875, -0.0424080268, &
 0.0655053258,  0.0890477374 &
]
            layer2_weights(1:32, 8) = [ &
 0.3528695107, -0.3990301490,  0.1174236983, -0.4027951956, -0.4792315364,  0.2199057192,  0.3387450278, -0.5230839252,  0.6186738610, -0.3840564489, &
 0.1532728523, -0.3301762938,  0.1950449646,  0.5796399117, -0.1679775119,  0.4103717208, -0.4193055332,  0.4641932249,  0.1626560390, -0.5748155117, &
-0.0076254825, -0.2498753816, -0.3665625751, -0.4935036898, -0.4504934847,  0.2525208890,  1.1129251719, -0.2727185488, -0.6625941992, -0.4123156965, &
-0.1252921522,  0.3470989168 &
]
            layer2_weights(1:32, 9) = [ &
 0.3570242226, -0.7726375461, -0.5887324214,  0.0725532472,  0.7524659634, -0.3618246615, -0.2049285173, -0.6466998458, -0.3774491847,  0.3211338222, &
-0.1654825360,  0.1232739910, -0.0313628837,  0.6583848596, -0.0614890568,  0.8322750926, -0.5688551068,  0.8681534529, -0.4273970127,  0.6721430421, &
-0.3348887861,  0.3730355203,  0.4398875833, -0.1658501774, -0.4830943942, -0.1553606242, -0.0862771869, -0.1112964228,  0.0612961501,  1.0163435936, &
-0.0108737154,  0.3751357496 &
]
            layer2_weights(1:32, 10) = [ &
-0.1868805438,  0.0083669126, -0.5960487723,  0.0978605673,  0.4521133602,  0.9576968551,  0.0954291224, -0.4305392504,  0.1001742184,  0.0831875280, &
-0.4117503166, -1.1508913040,  1.2913031578,  0.2444206327, -0.2336759418, -1.0326615572, -0.7202050686, -0.6139895916, -0.4727653265, -0.1798615456, &
-0.5296275020, -0.1460148543, -0.3246189952, -0.6118876338, -0.0025048256,  0.4998820424, -0.0916897804,  0.9170172811, -0.5127206445,  1.4316198826, &
 0.1574702561,  0.0815110579 &
]
            layer2_weights(1:32, 11) = [ &
-0.4583729804,  0.8025556207,  0.2653380036,  0.1421491653,  0.0326175354, -0.5996483564, -0.1295913160,  0.5378141999,  1.1422201395, -0.2359929532, &
-0.4554743767,  0.0632235929,  0.2424900681,  0.4043477178,  1.0363818407, -0.5466323495, -0.7369800806, -1.7570643425,  0.0959701315,  0.3278536499, &
-0.1867557913, -0.0384691879,  0.0157788526, -0.4960730970, -0.5716036558,  0.0799119323, -0.2621812224,  1.5270215273,  0.3143619895, -1.2965760231, &
-0.2380885929, -0.1560496539 &
]
            layer2_weights(1:32, 12) = [ &
-0.5418975949,  0.3065346777, -0.5787068009, -1.3334833384, -0.3485212624, -0.0745237991,  0.0164616816, -0.4068641067,  0.0000183589, -0.2688062787, &
-0.7927654982, -1.2050611973, -0.5390350819,  0.8478212953,  1.0461126566, -0.2601957023, -0.4007803798, -0.5847135186,  0.9067929387, -0.5216986537, &
-0.1319888979, -0.3512083292, -1.7226274014, -0.2257443815, -0.4815833271,  0.3554005325,  0.1180849597,  1.0962871313, -0.6774270535,  0.0214991607, &
 0.0467544571,  0.4451801777 &
]
            layer2_weights(1:32, 13) = [ &
-1.3087830544,  0.3565394282,  0.9161375761, -1.2763688564,  0.0592977479,  0.0685954317, -2.0256409645,  0.1768002063,  0.3676537275,  0.1466285288, &
-0.1319314241, -0.3188083470, -0.2870417833,  0.6993387341,  0.3614208698, -1.6606332064, -0.3812944591, -0.1806031466,  0.6321813464, -0.3669337034, &
-0.1610701680,  0.6264804602, -1.2600668669,  0.3860316873,  1.2266696692,  0.0688274503, -0.4203882515,  1.3568719625,  1.3458323479,  0.1493611187, &
-0.2498327792,  0.5375260711 &
]
            layer2_weights(1:32, 14) = [ &
 0.8457725644,  1.2553305626, -0.2492739111,  1.0908565521,  0.4818371832, -0.4385064840,  0.3906564116,  0.0241937283,  1.3173333406,  0.0255135242, &
 0.7397822738, -0.5322951674,  2.6923890114, -0.3091188073,  0.4065316021,  0.6328278780,  0.7375192046, -0.7059828639,  0.4317001402, -0.1539376378, &
-0.0040234611, -0.1008232459,  0.1515256464, -0.6061243415, -0.1799952984,  0.3022109568,  0.4079576731,  1.4443646669, -0.3844937682, -2.1123673916, &
 0.0970873460,  0.0928475112 &
]
            layer2_weights(1:32, 15) = [ &
-0.1586326361, -0.1976725459,  0.1324434131,  0.2689233124, -0.4843940139,  0.7009179592, -1.3096014261,  0.2674632668, -0.2311887741,  0.0801727772, &
-0.1419263780, -0.2822762728,  1.4846458435, -0.2291814983, -0.3721415401, -0.6687753797,  0.9667931795,  0.5131516457, -0.0877864957, -0.6062520742, &
 0.6155862212, -0.6732789874, -0.1203798950, -0.0926228464, -0.2246354669,  0.1145614237, -0.0401487574, -0.0496088155, -0.8179233074,  0.8218536377, &
 0.1133916005, -0.3914289773 &
]
            layer2_weights(1:32, 16) = [ &
 0.0375378653,  0.5227128267, -0.9551468492, -0.2703426480, -0.0983831584, -0.0172170494,  0.2105376124, -0.9736785293, -0.1570191681, -1.0101174116, &
-0.5564332604,  0.2361806482, -0.1314199865, -0.0907669067,  0.6522569656,  0.3922398388, -0.2143952698, -1.3344026804,  0.0581336096, -0.2971068621, &
 0.0343392789,  0.5267069340, -0.4310333133, -0.1947579533, -0.0150814764,  0.7189394832,  0.9223455787,  0.3270768821,  0.3059192896, -0.8507819772, &
-0.0468546674, -1.4574869871 &
]
            layer2_weights(1:32, 17) = [ &
 0.2890374064, -0.9670605659, -0.2978681028, -0.2024719268,  0.1869535446, -0.2721711993,  0.0561608449,  0.1942068338, -0.1178272963,  0.2821560204, &
 0.2418793738, -0.1161925644,  1.1900467873, -0.1434443444, -0.0057334392, -0.0832984149,  0.6562683582,  0.8284804821, -0.6795125604,  0.3105773330, &
 0.9447038174,  0.4257474542,  0.5578699112, -0.5012803674, -0.1128131449, -0.1418106109, -0.3197880089, -0.3340194225,  0.1396161020,  0.6549223065, &
 0.0747145638,  0.2371797860 &
]
            layer2_weights(1:32, 18) = [ &
 0.3060773611,  0.0702921003,  0.4652033448,  0.1387861222,  0.1143386140, -0.1838692278, -0.4455583096, -0.1007548422,  0.1669275463, -0.8472665548, &
-0.3851014674, -0.1595564038,  0.6010911465, -0.1009359285, -1.4664398432, -1.9258478880, -0.1052026600, -0.8187035918,  0.1983003914,  0.3633865118, &
 0.0931725129,  0.1387427300,  0.0574014522,  0.3614567518, -0.0778405145,  0.1451286376,  0.5967825651, -0.3674576283,  2.6688401699,  0.9200224876, &
-0.1499923766,  0.0536908843 &
]
            layer2_weights(1:32, 19) = [ &
-0.0561037920, -0.0154358987,  0.1549963653,  0.3442565203,  0.3746824861,  0.5432567596, -1.1442948580,  0.0516098514, -0.1928313673,  0.3138828278, &
-0.2692652047,  0.4544413984,  0.3711204827, -0.6305075288, -0.6164786220, -1.1566547155,  0.2901532054, -0.3251706362, -0.0163005777, -0.3499420881, &
 0.0105303796, -0.3472370505, -0.0449080430, -0.0692296699,  0.3630416989, -0.1432564408,  0.4930249751,  0.0697428659,  0.4574914575,  0.4923749566, &
-0.0910028517, -1.1956808567 &
]
            layer2_weights(1:32, 20) = [ &
-0.1900334358, -1.0571843386, -0.5476910472, -0.1657687277, -0.0329853259,  0.2132179737, -0.5712743402, -0.2351495922,  0.1647705287, -0.2808282673, &
-0.5626580119, -0.2268424332,  0.8010977507, -0.3026411533,  0.0843798220, -0.2319606692,  1.0694411993,  0.8974612355,  0.3447966576, -0.2470899075, &
 0.5597208142, -0.3596094251, -0.0961221009,  0.0929998755, -0.1904302090,  0.1829777062,  0.1457909942, -0.5683691502, -0.1567453295,  0.1920369714, &
-0.0127419038, -0.4275092483 &
]
            layer2_weights(1:32, 21) = [ &
-0.5272637010,  0.3047649562,  0.6509110332,  0.4695928693, -1.6483142376, -0.8383501768, -0.4399273396,  0.7874405384, -0.9046065211,  1.6425129175, &
-0.3064153790,  0.4456861019, -1.1930836439,  0.3536917865, -0.0310721155,  0.5744511485, -0.8163875341,  0.1634766012, -1.4647924900, -0.2859719396, &
-0.8340588212,  0.5467676520, -0.0394302942,  0.1008682549,  0.7581585646, -0.4377642572,  0.2941994071, -0.3772789836, -0.6892547607,  0.2664318979, &
 0.1782407463, -0.0901418477 &
]
            layer2_weights(1:32, 22) = [ &
 0.3863298893,  0.5827362537,  0.0611906089,  0.1368168294,  0.2531850040, -0.4247721434,  0.6299726963, -0.1181281880, -0.4198439717,  0.2691678405, &
 0.4221951365, -0.7885939479,  0.3901793361, -0.0094619729, -0.1302881837, -0.0426641256, -0.5932339430,  0.0690639019,  0.2946295142,  0.6029684544, &
-1.9673807621,  0.2277245373, -0.0484181494,  0.3402453363, -0.7429841757, -0.1223739088, -0.1233124956, -0.4936252832,  0.5253100991,  0.1221597940, &
 0.0136422394,  0.1155724302 &
]
            layer2_weights(1:32, 23) = [ &
-0.1455209404,  0.3381749690, -0.7238200307, -0.2037036270,  0.4097642004,  0.7344919443, -0.0913277864,  0.6418557167,  0.9338603616, -0.2539425790, &
 0.6889059544,  0.6471998096, -0.6389237046, -0.5012099147, -0.1080306545, -0.0857020542,  0.4242104888,  0.1464901567, -0.8195320368,  0.1208158433, &
 0.0829489306,  1.1773321629,  0.2008178681,  0.0160775892,  0.2827983797, -0.3805882335,  0.5103205442, -0.5597203970,  2.3450191021, -0.3023870289, &
 0.3261844814,  0.8117908239 &
]
            layer2_weights(1:32, 24) = [ &
 0.1776593924,  0.1059192121, -0.0160779767,  0.0749614611,  0.9087491632, -0.3981012702,  0.3152507842, -0.4492442608, -0.6085335612,  0.3499572873, &
-0.2424488962,  0.6329888105, -1.4941956997, -0.1137081310, -0.2235317528,  0.2439885139, -1.2031517029, -0.5648013949, -0.6350770593,  0.8198293447, &
-0.2906939983, -0.0455140956,  0.7497249842,  0.4597938657,  0.1749755144, -0.1972159296, -0.0890438482, -0.1965645999,  0.1667608768, -0.4422142804, &
 0.0809080154,  0.9990943670 &
]
            layer2_weights(1:32, 25) = [ &
-0.0567817762,  0.2105266750, -0.3733023703, -0.4803369641,  0.7013050914, -0.3029477298, -0.0488181785,  0.1828848869, -0.3079158962, -0.1025335565, &
 0.2682091594,  0.2381451875, -0.5541502833, -1.0634717941, -0.1526827663, -0.3641072810,  0.0933548659, -0.9373720884,  0.0802296698,  0.1835448146, &
-0.2202680707, -0.0418747514,  0.4139998257,  0.2381048203,  0.3257614970, -0.5500856638, -0.9059572220,  0.3387125134,  0.9124798179, -0.6926385164, &
-0.0514444858, -0.2519065738 &
]
            layer2_weights(1:32, 26) = [ &
-0.6511622071,  0.4899527431, -0.7792811990,  0.4190945327,  0.2242573351, -0.3805058002,  0.2272813171,  0.1253527403, -0.2384643108,  0.0155268312, &
-0.4039854109, -0.2167163044, -0.1430896521,  0.5157325864,  1.0618234873,  0.5411999226, -1.0664317608, -0.3022183180, -0.4595485032,  0.6306253076, &
-0.5793686509,  0.8917642832, -0.2528383732, -0.7389681339,  0.1877112240, -0.1928728372, -0.2248348892, -1.1127018929,  0.6145220995, -0.0468415469, &
-0.0421699882, -0.3309343159 &
]
            layer2_weights(1:32, 27) = [ &
 0.4050357044, -0.4721186459,  0.1893802583,  0.9362335205,  0.0482857451,  0.5516963601, -0.4845748246,  0.8055821657, -0.1968032569,  0.1025602967, &
 0.4084629416,  0.7259178162,  0.3389672339, -0.4731283486,  0.3144119978,  0.2997092903, -0.6740648150, -0.1260137111, -0.5396281481, -0.1984722465, &
-0.2568992674, -0.3109881580,  0.3335425556,  0.2427697182,  0.1716257632, -0.1535529196,  0.2885340750, -0.0918350592, -1.6383981705, -0.0941593200, &
 0.0863448307,  0.6653833985 &
]
            layer2_weights(1:32, 28) = [ &
 0.1551894397,  0.8098555803,  0.0365328602, -1.9394181967, -0.6869938374, -0.0037050724,  0.4970076084, -0.5909907222,  0.4304637313, -0.8181561828, &
-0.3102376163, -1.8379876614,  0.5500493646,  1.1227654219, -0.1005015224,  0.2251311839,  0.1460932791, -0.5225291252,  1.2891700268, -1.0157814026, &
-0.1079910845, -0.3661961854, -1.6809743643, -1.0203706026, -0.8223339915,  0.5089871287,  0.2686676085,  0.2228277624, -0.7317332029, -0.2747662663, &
-0.2535444796,  0.0071854908 &
]
            layer2_weights(1:32, 29) = [ &
-0.1502795219, -0.3124810159,  1.0508794785,  0.2070683241, -0.4104484916, -1.0068459511, -0.1686216891,  0.7361302972, -0.7510288358,  0.1733068079, &
-1.1304550171,  0.1328634918, -0.8897592425,  0.8228756785, -0.0578880310, -0.3839658797, -0.3283557594,  0.3830389380, -0.5805236101,  0.1253016293, &
 0.3814855814,  0.2828719318, -0.7679685950,  0.2458315641,  0.3907050490, -0.3114743531, -0.2612227201,  0.8441687226,  0.3838717043,  1.0070496798, &
-0.2337826341, -0.1747502536 &
]
            layer2_weights(1:32, 30) = [ &
-0.0993461758,  0.4451004863, -0.6157423854,  0.7969917655,  0.6993889809, -0.0592412092, -0.4851531386,  0.9574552774,  0.1316845864,  1.0440000296, &
-0.0316241793,  0.4347536862, -0.9206507206, -0.6284775734, -0.5733256936, -0.7558493018, -0.5598548651, -0.3408925831, -0.6935141683,  0.3717618287, &
-0.5496952534, -0.0378658623,  0.6647986770,  1.0015747547, -0.0345873013, -0.0555919856, -0.5405573249,  0.5380617976,  0.0250294060, -0.1807606518, &
 0.5464619994, -0.2933793068 &
]
            layer2_weights(1:32, 31) = [ &
-0.4501203597,  0.6192702651,  0.5125336647,  0.5980922580, -0.6766891479,  0.3990427256,  0.1997998655,  0.6598914266,  0.8182736039,  0.2714072466, &
-0.8934485912, -0.2431139946, -0.8979959488, -0.1008555964,  0.7960368395, -0.3253306746,  0.0172714330, -1.6794552803,  0.5632947683, -0.6180394292, &
 0.1703865677, -0.2084469348,  0.2478161156,  0.6414464116,  0.2067778707,  0.4248542786, -0.5448301435,  0.9472691417, -1.1723632812,  0.3014614284, &
-0.0030817760, -0.2265381217 &
]
            layer2_weights(1:32, 32) = [ &
-0.3418591022,  0.3000234067,  0.6004496217,  0.2733252943, -0.4172929227,  0.4762250781, -0.8978636265,  0.3556045592, -0.6300259233,  1.5152648687, &
-0.0590502918,  0.1052905321, -0.1753295362, -0.6186721325, -0.2147610486, -0.8250132203, -0.0322528481, -0.1034988016, -0.1053528264,  0.3449743986, &
-0.5675410628,  0.2896705270,  0.0338626429, -0.2973371148,  0.2013085186, -0.5477738976,  0.4758824110,  0.0360789038,  0.0590841956, -0.0745415166, &
-0.0314910859, -0.7881255746 &
]


            layer3_weights(1:32, 1) = [ &
-0.0328347199, -0.3712200820, -0.2636986673, -0.2623629272,  0.4869327843,  0.5577959418, -0.1953481287, -0.7101480365,  0.7106323838,  0.3426123857, &
-0.5344603658, -1.7769266367,  1.5734429359,  0.1750737876,  0.2124642581, -0.0292898342, -0.1208366081, -0.5835818648, -0.2384444326, -0.7674300075, &
 0.7139701247,  0.8698343039,  0.7406536937,  1.3173890114,  2.1667001247,  0.8841931820,  0.7158592939,  0.2101841271, -0.1843615919, -0.6214962006, &
-0.4377826452, -0.2453686297 &
]
            layer3_weights(1:32, 2) = [ &
-0.0532978512, -0.6988900304,  0.3808387220, -0.7733625174, -0.8523944020, -0.0066633262, -0.5563107133,  0.2581884265, -0.5594645739,  0.9624466896, &
-0.8006927371,  1.7976039648,  0.6477437615,  0.4949974716, -0.3563638330, -0.0695048347, -0.7463216186,  1.2554717064,  1.0776832104,  0.7807793021, &
-3.5781536102,  1.2217696905,  0.1889679432, -0.1267082989, -0.0985713303, -0.0657407716,  0.2338796705, -0.3477695882, -0.6926425099,  1.2425211668, &
-0.1232991368,  0.5618878007 &
]
            layer3_weights(1:32, 3) = [ &
-0.4012371004,  0.1930385083, -0.4083134830, -0.1241908297,  0.7886758447, -0.1406031698,  0.5183385611, -0.4481900334,  0.1426134408,  0.7889202833, &
 1.0072696209, -0.3794257939, -1.0785243511, -0.5599982738,  0.3338393569,  0.7452644110,  0.7452339530,  0.2989153862,  0.2215307802, -0.9249981046, &
-1.4550710917,  0.3748080134, -0.1831510067,  0.0580131523,  0.3461224437, -0.0877375975,  0.1299128830, -0.6095644236,  0.0584169514,  0.9915259480, &
-0.7351161242, -0.9054025412 &
]
            layer3_weights(1:32, 4) = [ &
-0.0158818029, -0.1872700006, -0.1035467982,  0.3042108119, -0.1585126519,  0.4058082402, -0.1122347936, -0.1211563274,  0.1414548159,  0.1337130070, &
 0.1279079616, -0.6599172354,  0.6028795838,  0.1513221264, -0.5870900154,  0.0024859020, -0.0833478495,  0.2163075656,  0.2703205645, -0.7531758547, &
-0.0040519680,  0.3279814422,  0.1289143860,  0.2906988561,  0.8243851066,  0.1495835632,  0.2260738313, -0.6677341461,  0.6113864183,  0.2368057370, &
-0.1842364669,  0.3299450874 &
]
            layer3_weights(1:32, 5) = [ &
-0.3859724700, -0.1764896363, -0.8330670595,  0.2415163070, -0.9978259802,  0.8174155951, -0.2063707858, -0.2988893688, -0.1834523678,  0.4257307351, &
-0.2895935178, -0.8988668919,  0.6733017564,  0.1215572283,  0.2217669189,  0.4310520589, -0.0870975330,  0.9428285360,  0.3955358863, -0.3144649863, &
-0.0019472045,  0.2360626608,  0.8781983852,  0.7737663388,  0.6790525913,  0.4395715296,  0.2375013679, -0.6603064537,  0.1369058937, -0.0275579691, &
-0.6838819385, -0.0519809648 &
]
            layer3_weights(1:32, 6) = [ &
 0.0343400352, -0.0274241008, -0.2836166024,  0.6646673083,  0.6162190437,  0.1059619710,  0.1271693110, -0.4105750918,  0.0708842725,  0.3064111769, &
-0.3598617613, -0.0740924329,  0.0921315253,  0.7560228109, -0.4074921012,  0.5264368057,  0.3166342080,  0.4948467314,  0.2671617568, -0.5352452397, &
 0.1362865567,  0.7755349874, -0.2036686838, -0.1776374131,  0.9328400493,  0.1349782944,  0.8015303016, -0.7247989178, -0.1521481574,  0.0685803816, &
-0.1726099551, -0.1727790833 &
]
            layer3_weights(1:32, 7) = [ &
 0.0106489789,  0.1754647046,  0.2952050865, -0.9119235277, -1.1056603193, -0.8921386600, -0.2207606584, -0.9421029687, -0.0957966670,  0.5631095171, &
-0.0184093919,  1.6164575815,  1.0627769232,  0.1059304178,  0.5264164805, -0.7202436924,  0.0902971700,  0.2732586265, -0.0199762527,  0.9131178260, &
-0.3472043276, -0.4827766120,  0.0453560166, -0.1123308688,  0.3129114807,  0.0823544115,  0.5600563288,  0.6717007160, -0.2590760589,  0.8733323812, &
-1.1192537546,  1.1036533117 &
]
            layer3_weights(1:32, 8) = [ &
-0.0501971580, -0.1153306812, -0.5219532251,  0.5933540463,  0.2351425290,  0.5370235443, -0.0082036760, -0.0908987746,  0.1003013998,  0.5607113242, &
 0.0012630495, -0.8242222071,  0.6012783051, -0.0519295074, -0.2013719380,  0.2623400986, -0.4763203561,  0.2115922868,  0.5838240981, -0.5645163655, &
 0.6491139531,  0.8462546468,  0.4272283316,  0.3013805449,  1.1722955704,  0.0934875011,  0.7758327723, -0.6061757207, -0.4627825618,  0.0994018912, &
-0.4286805689, -0.0210401025 &
]
            layer3_weights(1:32, 9) = [ &
-0.3163397610,  0.2597802877,  0.3543668389, -0.2556422949,  0.0498873964, -0.2179896683, -0.6122334599, -0.1265131682,  0.0672565624, -0.0201782342, &
-0.3869194686,  1.1248530149,  0.9044551253, -0.0547367893, -0.4727513790, -0.5466538668, -0.4806208313, -0.0969535410,  0.5070754886, -0.6598341465, &
-0.0864845067, -0.2294031978, -0.0265544206,  0.2486445755, -0.0223492831, -0.4047763348, -0.2935756147, -0.2702698112, -0.0343739204, -0.1671899706, &
-0.3061737716,  0.4384591579 &
]
            layer3_weights(1:32, 10) = [ &
 0.0228959676, -0.3510871828,  0.1596372575, -0.2635661364,  0.4494991004,  0.5009591579, -0.0351087600,  0.4219488800, -0.4055189192,  0.3348225653, &
 0.3080019653, -0.4051041603,  0.1087751612, -0.1765423119, -0.0209013876,  0.1164095774, -0.3624899387,  0.2502312958,  0.1639550179, -0.3190726340, &
-0.0265682116,  0.2823390663,  0.3326704800,  0.5392349362, -0.0589532070,  0.3108260930,  0.7505174279, -0.1582725942,  0.2753227651,  0.0322501995, &
 0.5768098235, -0.1017343849 &
]
            layer3_weights(1:32, 11) = [ &
-0.1751906276,  0.2330985665,  1.2404627800,  1.0029937029,  0.8228349686,  0.3032574058, -0.5700559020,  0.2086018324,  0.4379022717, -0.9274221659, &
-0.1857190132,  0.5204645395, -1.3311967850, -0.5360906720, -0.3519191444, -0.6773725152, -1.2446419001, -0.0679957271, -0.0130921649, -0.2938113809, &
 0.0247697178,  0.3053666651, -0.1005045995, -0.4620159566, -0.4933553636,  0.4411425591, -0.4006066620, -0.1425819695,  0.0211134255, -0.6666834354, &
 0.2074387670, -0.6404111981 &
]
            layer3_weights(1:32, 12) = [ &
 0.0702145845, -0.0886371285, -0.3445425034,  0.3104277849, -2.3009419441, -0.4831788838, -1.2146222591,  0.3662520945, -0.3006136417, -0.0499810129, &
 0.1741685420,  0.4507223368,  0.4993775785, -0.9929661751, -0.2688777447, -0.2974777222, -0.5026423335,  0.0603421256,  0.1688162535,  0.5890274644, &
-0.0966171250,  0.2227975428, -0.5881112814, -0.5172519684, -0.4778688252, -0.2754320800,  0.0707278699,  0.1268826574, -0.2794055939,  0.0719391629, &
 0.3091891706,  0.4011597335 &
]
            layer3_weights(1:32, 13) = [ &
-0.3813408911,  0.0208664387, -0.2756403387,  0.7943304777, -0.2953721285, -0.1756188571,  0.4890086055, -0.1409270018, -0.2798967957,  0.3823868632, &
 0.4100687504, -0.4475127459,  0.0308391191,  0.0290563926, -0.0756119490, -0.5775973797,  0.0906577334,  0.0195988361,  0.3201723695,  0.0838638023, &
-0.0739952549, -0.8876280189,  0.2547134757,  0.2388735116,  0.6132405400,  0.3620383143,  0.0333634615, -0.9852182269, -0.4390905201, -0.2630456388, &
-0.1447395980, -0.2920289338 &
]
            layer3_weights(1:32, 14) = [ &
-1.2565103769,  0.7741675973,  1.1124831438,  0.1218708083, -0.6881440282,  0.1015548259,  0.5657555461, -0.1880185008, -0.7159459591,  0.4991491735, &
 1.0570989847,  0.7524582744, -1.6278871298, -0.2811807692, -0.2031172663, -0.6460805535,  0.5890839100, -0.0141409142,  0.0517211407, -0.3964866102, &
-0.2032955140, -0.2742090523, -0.4391715825, -0.3978090286, -0.2566967010,  0.4402861893, -0.4683738649,  1.1446015835, -0.2358554751, -1.3408060074, &
-0.5626116395, -0.8497861624 &
]
            layer3_weights(1:32, 15) = [ &
 0.4069614708, -0.2844674885,  0.0783997104,  0.2064290345, -0.0234455708, -0.1967842579,  0.2858097553, -0.8136095405, -0.4080928266,  0.2162040174, &
-0.5243005753, -0.1877159327,  0.1243162379,  0.0726369172,  0.3664725423, -0.3059610128, -0.0994481146,  0.0214215536, -0.4357985854, -0.1083964333, &
-0.1743452400, -0.0864285156, -0.1045778617, -0.2705181241, -0.3960011303, -0.5059494376,  0.0245548766, -0.3453388512,  0.4776223302, -0.4695615172, &
 0.3141618371,  0.3934185803 &
]
            layer3_weights(1:32, 16) = [ &
 2.1512913704, -1.7745016813,  0.3997862041,  0.7939555645,  0.3020715415, -0.8420619369, -0.0818672404,  0.3505130112, -1.8033773899, -0.9749872088, &
 0.3645400107, -2.5894010067,  1.7319153547,  1.6731156111,  1.7412472963, -0.1972405612,  0.8528378606, -0.7473897338,  2.7306683064,  1.6674827337, &
 0.5633398294, -2.8293135166,  0.4733448625, -0.4212678969,  1.6902081966, -0.2943841815,  1.4796689749,  0.1223104224, -2.1060628891, -0.0061848001, &
-0.7722433209, -0.0865504891 &
]
            layer3_weights(1:32, 17) = [ &
-0.7232201695,  0.1624615490, -0.7122786045,  0.6197054982, -0.0029496448,  0.3367020786,  0.0452110395, -0.6497848630,  0.3199215233, -0.0667839348, &
 0.1446807683, -1.3869384527,  0.8689534068,  0.3738384247, -0.8144435883,  0.2198267579, -0.0613615327,  0.3484490216,  0.1986268461, -0.1742840409, &
 0.4509603679,  0.5165908933,  0.6898586750,  0.7050718665,  1.5407048464,  0.7139560580,  0.4985629022, -0.6472711563,  0.6678232551, -0.3091195822, &
-0.0093461648,  0.1261132956 &
]
            layer3_weights(1:32, 18) = [ &
 0.4264568985,  0.8129687309,  0.2808019519, -0.0096241795, -0.0061988481,  0.1517041177, -0.1088932827,  0.0819036290, -0.7566410303, -0.5447843671, &
-0.2336424291, -0.4015963376, -0.5626710057, -0.0102478312,  0.1661593616,  0.3429003656, -0.5649049878, -0.2984195352, -0.8581443429, -0.2244018018, &
 0.3801160455, -0.7379682660, -0.0437797979,  0.0541673154, -0.6360211372,  0.1779509634,  0.1735058725, -0.2588855326, -0.3984175622, -0.8829823136, &
 0.0422597528, -0.7908867598 &
]
            layer3_weights(1:32, 19) = [ &
-1.1301944256, -0.1927391142, -0.2532044351,  0.1702903956, -0.3680842817,  0.6335312128,  0.2887712419, -1.0055185556,  0.7164658904,  0.6872745156, &
-0.6162639260,  0.2368119359,  1.2487571239, -0.3128771186, -1.0149031878, -0.0304209311,  0.3143149614,  0.8484900594,  1.4143384695, -0.7284529209, &
 0.3436296284,  0.5204079151,  0.5712003112,  1.1257636547,  0.7648278475,  0.7916433811, -0.2286174148, -0.2568172514,  0.9215229750, -0.4295896590, &
 0.2357643098,  0.0675900280 &
]
            layer3_weights(1:32, 20) = [ &
 0.8561294079, -0.2595941424, -0.5085799098, -0.5453819633,  0.1693159044, -0.4843104780,  0.3950004876, -0.3193080723, -0.7709904313, -0.9736152291, &
 0.4565913975, -0.2157305032, -0.3657326102, -0.3721837103,  0.2559351325,  0.2145200372, -0.1543777585,  0.1179369986,  0.3285664022,  1.1679189205, &
-0.5902547836, -0.1108900905, -0.4559399486, -0.3722440898, -0.3760361075, -0.9207291007, -0.4040367007,  0.0161339696, -0.5731813908,  0.4630778730, &
 0.4616883397,  0.5402876139 &
]
            layer3_weights(1:32, 21) = [ &
 0.0999981984, -0.2009931505,  0.0126875080,  1.0210988522, -0.8275666237,  0.1282207966, -0.2629651427, -1.0207437277,  0.2441734672, -0.0663023964, &
-0.7782535553,  0.0341390036,  0.2231764942,  0.1621163189,  0.3278558850,  1.0213006735,  1.7424529791,  0.0527044646,  0.4410589337,  0.1730955988, &
-0.2030703872,  0.8858591914, -0.6465027332, -0.3742554784,  0.9955609441,  0.1322639883, -0.2629491091, -0.2657081485, -0.1163472682,  1.5832468271, &
-0.1325042546,  1.1013292074 &
]
            layer3_weights(1:32, 22) = [ &
-0.7429770231,  0.2328024507, -0.1572995633,  0.5143279433, -0.2834865153,  0.0476423539, -0.3735742569, -0.6894420981, -0.1752232313,  0.0096326191, &
-0.2095190883, -0.1490599811, -0.4909765124,  0.1772064865,  1.0781409740, -0.3597529531,  0.0265939031, -0.4837067127, -0.5329648852, -0.5566613674, &
-0.0346470065,  0.2382889539,  0.2067097574, -0.7429358959,  0.0362467915,  0.1895455718,  0.2178096026,  0.0041305874,  0.0968536437,  0.2097382843, &
 0.2483915836, -0.5793518424 &
]
            layer3_weights(1:32, 23) = [ &
 0.1158113182, -0.8237803578,  0.6883438826,  0.3707484603,  0.3170382380, -0.1788366288, -0.2768711746, -0.1102288291, -0.2145565152,  0.3645800948, &
 0.7117874026, -0.4614796937, -0.4805499017,  0.8959913254, -0.9364883900, -0.6735742688, -0.5725790858,  0.2188594788, -2.6244544983, -0.1358230710, &
 0.8447026610, -0.3302804232, -0.0477765985,  0.0700205117,  0.3795924485,  0.0618937537,  0.1448989213, -0.5507968068, -0.3409157395,  0.2428293675, &
 0.1122404337, -0.2801518738 &
]
            layer3_weights(1:32, 24) = [ &
-0.7828108668,  0.4313302934,  0.3830147088,  0.3667556345, -0.1077326462, -1.8128252029,  0.9601042867,  1.6095283031, -0.3518865705, -0.0546781123, &
-0.2312777936,  1.1893862486, -0.4780910015,  0.3166010082, -0.0281849429, -0.4129290283, -0.2198176533,  0.0683708861,  1.1401381493,  0.0046491837, &
-1.0739120245, -0.1690085083, -1.2239712477, -0.8357533216,  0.2409264594,  0.6899461150, -2.7319765091,  1.1831692457, -0.5866982937,  0.8874474168, &
-0.1761268228, -0.0150527190 &
]
            layer3_weights(1:32, 25) = [ &
 0.3827576637, -0.1024143398, -0.4631104171,  0.0252786893, -1.4261629581, -0.4733167887,  0.4982044995,  0.3374898434,  0.2295046002, -0.3428125381, &
 0.4683220387, -0.2997670174, -0.0625352785,  0.1380430311,  1.7323138714,  0.5724684000,  0.6148988605,  0.2083295733,  0.9550590515, -0.3566590548, &
 0.0371135697, -0.0525898337, -0.3391553164, -0.3030884862, -0.0631835982, -0.3483948410, -0.0201834682, -0.1187299937, -0.8159192204,  1.0807210207, &
 0.3676406741,  0.2078966051 &
]
            layer3_weights(1:32, 26) = [ &
 0.0660123229,  0.1976189464,  0.3221557438,  0.1093646884, -1.2520015240,  0.1704247147, -0.4337832332,  0.6148375273,  0.3270445764,  0.6986601353, &
 0.6668143868, -1.1762101650, -0.2330225110,  0.8480002880, -0.3271408379,  0.0936638191,  0.1874380112,  0.2039530277,  0.5007686019,  0.2614751458, &
-0.2616656423, -0.7549210787, -0.0894643292, -0.3687579036, -0.5793058872, -0.4200688899,  0.0198130533, -0.9593524933,  0.2052018344, -0.0346836187, &
-1.0720901489, -0.5598627329 &
]
            layer3_weights(1:32, 27) = [ &
-0.1208048686,  0.7394621968, -1.5774438381,  1.8298639059, -2.3279626369,  0.8011197448,  1.8765381575, -0.3320547342, -0.9873587489, -1.1061778069, &
 0.2222219259, -1.2076691389,  0.6509633064, -1.4155470133,  1.1304312944, -0.9544355869,  0.3939599991, -0.3635082245,  1.5053660870,  2.0664327145, &
 1.2418607473, -4.5796079636,  0.7784056664,  0.5913560390,  2.0244433880, -0.2962610424,  0.4803052247, -0.1616194248, -1.4715242386, -1.1022740602, &
-0.2477813363,  1.1162991524 &
]
            layer3_weights(1:32, 28) = [ &
-0.3674188256, -0.8090556860,  0.4182504416, -0.0719705746,  0.3933155835,  0.3822844028, -0.3659533858, -0.7789784074,  0.7841641307,  0.2446225584, &
-0.2870826125, -0.9139266014,  0.7123172283, -0.4535509050, -0.3919626772, -0.2880880237, -0.0836712196, -1.6746491194,  0.4867512286, -0.6653424501, &
 0.2151816189,  0.8900648355,  0.8960070610,  1.1138263941,  2.9255814552,  1.0466291904,  0.3800471723,  0.3446781635, -0.3290718794, -0.5031996369, &
 0.0997890308,  0.3401639462 &
]
            layer3_weights(1:32, 29) = [ &
-0.7277055383, -0.1829648316, -0.3406372368,  0.8496348262, -0.5479894876,  0.4458763003, -0.4477780163, -0.0962310284,  0.2077644318, -0.0012851531, &
 0.2843744755, -0.1125055701,  0.0340242162,  0.2309570909, -1.6624299288, -0.0827899873,  0.0127387308, -0.0100858631,  0.5498334169, -0.3379564285, &
 0.1936126053,  0.5532866120,  0.1137671471,  0.3768092394,  1.3052825928,  0.6443192363,  0.3750819862, -0.9474409819,  0.4223541617,  0.2818794250, &
 0.5709148049,  0.3819026053 &
]
            layer3_weights(1:32, 30) = [ &
 0.3954937160, -0.0881137550, -0.7881743312, -0.5087893009, -0.9153207541, -0.1234143600, -0.2341916263, -0.2290287316, -0.1955164820, -0.1098781377, &
-0.3017490506, -0.4399648309,  0.5537247658,  0.0261386968, -0.0851158947,  0.0520219691, -1.0292114019, -0.5114058852, -0.4068602026,  0.7158691883, &
 0.0805243254, -0.8234438300, -0.0131029608, -0.1520397514, -0.0569960810,  0.1787322015,  0.4116455615, -0.3405836523, -0.5043638945, -0.2902579606, &
 0.1190360636, -0.1917565614 &
]
            layer3_weights(1:32, 31) = [ &
 0.1098559201, -0.2626636922, -0.0404672213,  0.1466282904,  0.1809242666,  0.3690993488, -0.0953279659, -0.3729917109,  0.1808848977,  0.2070506662, &
-0.4206775129, -0.2557873428,  0.4022980928,  0.9148455858, -0.6372256875,  0.3892813623,  0.6412417889,  0.7533457875, -0.0823346227, -0.9099929333, &
-0.5442481041,  0.3993012905, -0.1880366355,  0.2589285970,  0.7504011393,  0.4041997790,  0.3386220634, -0.7962806821,  1.0449820757,  0.1610308737, &
-0.0534823611,  0.1121434718 &
]
            layer3_weights(1:32, 32) = [ &
-0.1346758008, -0.0382732451, -0.0284486730, -0.3271655142,  0.6709268689,  0.0932558328,  0.0601174310,  0.5463578105,  0.2949586809, -0.2232638896, &
-0.1159163043, -0.2570021152,  0.1857274473,  0.2421673536, -0.1726556420,  0.5091409087,  0.4943207800, -0.1857893020, -0.4380236864,  0.4423107505, &
 0.2167023122,  0.0260570627,  0.1259323955,  0.0227480009, -0.5388374925, -0.2469947785,  0.0179727152, -0.2214554101,  0.3052076697, -0.1776152998, &
 0.0668248013,  0.1304764450 &
]


            output_weights(1:32, 1) = [ &
-0.0075672525, -0.0000039454,  0.0511866398, -0.0138442405, -0.0016508600,  0.0529468469,  0.0361821987, -0.0044641974, -0.0589747876, -0.0002440178, &
 0.1955550909, -0.1429624707,  0.0004101732,  0.0790441185, -0.5296680927, -0.0000008378, -0.0048740958,  0.1719491333, -0.0000031963,  0.7892174721, &
 0.0001289810, -0.4196316898, -0.0723109841, -0.1087025926, -0.6799224019,  0.2266739458, -0.0000036115,  0.0000008512,  0.0000080367, -0.2235832661, &
-0.0027626457,  0.8502069116 &
]
            output_weights(1:32, 2) = [ &
-1.4271032810,  0.0004773423, -0.0113380617, -3.4637334347, -1.1135426760, -6.1510577202, -0.0010040260,  2.5034430027,  0.0427071005, -0.0137948813, &
 0.0202769395, -0.0148766572,  0.0008329464, -0.0067843026, -0.0271756072,  0.0000902950,  1.3409465551,  0.0032442529, -0.0000985266,  0.0288089346, &
 0.0002496438,  0.0137545466,  0.0099462895,  0.0060909567, -0.0263215117, -0.0186634287,  0.0004172791, -0.0001698326, -0.0009613470,  0.0130781345, &
 2.3016107082, -0.0124887181 &
]
            output_weights(1:32, 3) = [ &
-21.6859111786,  0.0035649305,  23.0987434387,  0.1196708307, -28.5982608795,  8.2304763794, -8.1688251495, -28.0021057129, -22.6691036224, -61.4206085205, &
 4.1091938019,  16.7624797821, -40.5442810059,  7.2003593445,  3.1810557842,  0.0080809454, -8.4735116959, -21.6978073120, -0.0018710780,  10.0528202057, &
-50.8233795166,  1.2634832859,  6.3793792725, -0.2583494782,  22.0560932159,  6.4589023590, -0.0012205684, -0.0190481041,  0.0087379245,  3.5446026325, &
 16.5737628937,  2.8295650482 &
]

            layer1_biases(1:32) = [ &
 0.3974921405,  0.2865440845, -0.6392538548, -0.5736816525, -0.7444227338, -1.2388205528,  0.9053791761, -0.6262223125, -0.5807141066,  0.1613957882, &
-0.5484875441, -0.0366116501, -0.3096835613,  0.7838809490,  0.4282345176,  1.5663899183, -1.4241942167,  0.2101881057, -0.8339900970,  0.5159779191, &
-0.1018966213,  1.0286965370, -0.0231773145, -0.4021192491, -0.1708287895,  0.0522392578, -0.3496990204, -0.7863324285, -0.8802887201,  0.0908857957, &
-0.5313379765,  1.0133486986 &
]


            layer2_biases(1:32) = [ &
-0.0815836787,  0.4266039431, -0.2427051663, -0.1096710414, -0.2406626642,  0.0563561805, -0.2924866974, -0.2135729343,  0.1070862338,  0.3149513006, &
 0.2633659840,  0.2048241943, -1.2405942678,  0.5152869821, -0.3659499884, -0.0786305889, -0.0469236672,  0.1141790301, -0.3615777493, -0.1282240152, &
 0.2446082234,  0.4963075519,  0.4415651858,  0.5905601382, -0.1137141883,  0.3553441465,  0.2839191258,  0.1126062199,  0.4917777777, -0.2150488347, &
 0.0511028506,  0.1394585669 &
]


            layer3_biases(1:32) = [ &
 0.5713909268, -0.1067289859,  0.4354567230,  0.3716298044,  0.5780592561,  0.3500086367,  0.1166660786,  0.5259650946,  0.1702408791, -0.6485572457, &
-0.2705262601,  0.1816031933,  0.1277927309, -0.4722366333, -0.0257517528, -0.5570201278,  0.7290604711,  0.0781632811,  1.0371683836, -0.2325366288, &
 0.4607706368, -0.1807605624,  0.1440948248,  0.0363812856, -0.9318448305, -0.4993110597,  0.2086270452,  0.6927700639,  0.5681093335, -0.0553919263, &
 0.4459636807, -0.1547598094 &
]


            output_biases(1:3) = [ &
 0.0341124758, -0.0057104346, -14.0004596710 &
]

            layernorm1_weights(1:32) = [ &
 0.6569830775,  0.6457505226,  2.2168133259,  1.6554934978,  0.8088811040,  0.7227965593,  0.7528352141,  1.0610386133,  0.8234151006,  1.2059745789, &
 0.4871962965,  1.6035492420,  2.6940860748,  1.3052247763,  0.6673958898,  0.5635432005,  1.8032503128,  1.7966585159,  2.5320386887,  0.8798123002, &
 1.2564445734,  0.4378121793,  0.9460741878,  1.2920736074,  1.2558010817,  1.0545091629,  0.7079342008,  2.6860718727,  1.2596144676,  1.8909997940, &
 3.1099846363,  0.7171571255 &
]


            layernorm2_weights(1:32) = [ &
 1.3313670158,  2.1200499535,  1.7112662792,  0.9431065917,  1.4602526426,  1.0070211887,  1.8957695961,  1.3920241594,  1.0398210287,  1.1747980118, &
 1.4554114342,  2.2902839184,  3.5775179863,  1.1467121840,  1.4683550596,  1.3280729055,  1.4560172558,  2.3942327499,  2.5450685024,  1.5336527824, &
 0.8068885207,  0.9654551148,  1.3502930403,  1.1074298620,  1.3980475664,  1.1311573982,  1.1387857199,  5.6372051239,  0.8792868853,  1.5397642851, &
 1.2887114286,  1.5446077585 &
]


            layernorm3_weights(1:32) = [ &
 0.2216771096, -0.0000024745,  1.8506643772,  0.6140053272,  0.6490666270,  0.2918677926,  3.7141871452,  0.7720233798,  1.5827194452,  4.5777506828, &
 2.6754386425,  1.4694379568,  4.2383556366,  5.8342413902,  2.0230345726,  0.0000173433,  0.3063800335,  2.2199840546,  0.0000592159,  1.9127472639, &
 17.3169403076,  1.6491252184,  0.9957509041,  5.2322149277,  1.9092354774,  1.9537597895, -0.0000027198,  0.0000207287,  0.0001058576,  2.0661511421, &
 0.7625090480,  1.4785834551 &
]


            layernorm1_biases(1:32) = [ &
-0.3027767539, -0.1574493647, -0.0050678961, -0.7347115278,  0.2021715343,  0.2199021131, -0.6919518709, -0.3983671963, -0.1199161112, -0.7707913518, &
 0.1269641668,  0.1375629604,  0.0403315239, -0.3283041716, -0.5178064108, -0.6985534430, -0.0325410813, -0.1914232671,  0.6333533525, -0.1875131577, &
-0.0636784881, -0.5349473357, -0.2381584942, -0.0751458332, -0.4736205339, -0.7291923165, -0.3609522581,  0.2793696523, -0.6252654195, -0.0724348351, &
 0.2501333356, -0.8220909238 &
]


            layernorm2_biases(1:32) = [ &
-1.1878685951, -0.9464274049, -0.5857563019, -0.1161585748, -0.1369515061, -0.6688055396, -0.3951801360, -0.0351212248, -0.5887081027, -0.2758990228, &
-1.1650021076, -0.2255563140, -0.3062479794, -0.5024888515, -0.1752863973, -0.5123171806, -0.3604646027,  0.0523057096, -0.2758643329,  0.1789889336, &
-1.0656880140, -0.3238607049, -0.5758612156, -0.0051863291, -0.0516831540, -0.6574301720, -0.5305490494, -0.6517575383, -0.9488481283, -0.9578003883, &
-1.0381669998, -0.2432574630 &
]


            layernorm3_biases(1:32) = [ &
-0.4469405115, -0.0000043323, -0.0499260314, -0.3384517729, -0.6353605390, -0.0012814116, -0.7422128320, -0.5966049433, -0.0871381238, -0.1907606274, &
-0.1120681539, -0.2178204805, -0.1581730992, -0.7482237220,  0.1715945303, -0.0000019658, -0.3803447485,  0.0251084380, -0.0001028034,  0.7819757462, &
-2.1653070450,  0.2324876636, -0.1328787059, -1.1820272207,  0.8052260280,  0.1396968067, -0.0000028912, -0.0000340673, -0.0001017560, -0.3085949123, &
-0.2677164674,  0.1771624237 &
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

                use_equilibrium = has_equilibrium
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
                                            real( baseline_temperature, 4 )
            end if

            end subroutine estimate
end module droplet_model
