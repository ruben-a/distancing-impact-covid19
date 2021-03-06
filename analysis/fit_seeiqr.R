#' Fit the Stan SEEIQR model
#'
#' @param daily_cases A vector of daily new cases
#' @param daily_tests An optional vector of daily test numbers. Should include
#'   assumed tests for the forecast. I.e. `length(daily_cases) + forecast_days =
#'   length(daily_tests)`. Only used in the case of the beta-binomial (which
#'   isn't working very well).
#' @param Model from `rstan::stan_model(seeiqr_model)`.
#' @param obs_model Type of observation model
#' @param forecast_days Number of days into the future to forecast. The model
#'   will run slightly faster with fewer forecasted days.
#' @param time_increment Time increment for ODEs and Weibull delay-model
#'   integration
#' @param days_back Number of days to go back for Weibull delay-model
#'   integration
#' @param R0_prior Lognormal log mean and SD for R0 prior
#' @param phi_prior SD of `1/sqrt(phi) ~ Normal(0, SD)` prior, where NB2(mu,
#'   phi) and `Var(Y) = mu + mu^2 / phi`.
#'   <https://github.com/stan-dev/stan/wiki/Prior-Choice-Recommendations>
#' @param f2_prior Beta mean and SD for `f2` parameter
#' @param sampFrac2_prior `sampFrac` prior starting on
#'   `sampled_fraction_day_change` if `sampFrac2_type` is "estimated" or "rw".
#'   In the case of the random walk, this specifies the initial state prior. The
#'   two values correspond to the mean and SD of a Beta distribution.
#' @param sampFrac2_type How to treat the sample fraction. Fixed, estimated, or
#'   a constrained random walk.
#' @param rw_sigma The standard deviation on the sampFrac2 random walk.
#' @param seed MCMC seed
#' @param chains Number of MCMC chains
#' @param iter MCMC iterations per chain
#' @param sampled_fraction1 Fraction sampled before
#'   `sampled_fraction_day_change`
#' @param sampled_fraction2 Fraction sampled at and after
#'   `sampled_fraction_day_change`
#' @param sampled_fraction_day_change Date fraction sample changes
#' @param sampled_fraction_vec An optional vector of sampled fractions. Should
#'   be of length: `length(daily_cases) + forecast_days`.
#' @param fixed_f_forecast Optional fixed `f` for forecast.
#' @param pars A named numeric vector of fixed parameter values
#' @param i0 A scaling factor FIXME
#' @param fsi Fraction socially distancing. Derived parameter.
#' @param nsi Fraction not socially distancing. Derived parameter.
#' @param state_0 Initial state: a named numeric vector
#' @param save_state_predictions Include the state predictions? `y_hat` Will
#'   make the resulting model object much larger.
#' @param delayScale Weibull scale parameter for the delay in reporting.
#' @param delayShape Weibull shape parameter for the delay in reporting.
#' @param ode_control Control options for the Stan ODE solver. First is relative
#'   difference, that absolute difference, and then maximum iterations. The
#'   values here are the Stan defaults.
#' @param daily_cases_omit An optional vector of days to omit from the data
#'   likelihood.
#' @param ... Other arguments to pass to [rstan::sampling()].
#' @author Sean Anderson

fit_seeiqr <- function(daily_cases,
                       daily_tests = NULL,
                       seeiqr_model,
                       obs_model = c("NB2", "Poisson", "beta-binomial"),
                       forecast_days = 60,
                       time_increment = 0.1,
                       days_back = 45,
                       R0_prior = c(log(2.6), 0.2),
                       phi_prior = 1,
                       f2_prior = c(0.4, 0.2),
                       sampFrac2_prior = c(0.4, 0.2),
                       sampFrac2_type = c("fixed", "estimated", "rw"),
                       rw_sigma = 0.1,
                       seed = 42,
                       chains = 8,
                       iter = 1000,
                       sampled_fraction1 = 0.1,
                       sampled_fraction2 = 0.3,
                       sampled_fraction_day_change = 14,
                       sampled_fraction_vec = NULL,
                       fixed_f_forecast = NULL,
                       day_start_fixed_f_forecast = length(daily_cases) + 1,
                       pars = c(
                         N = 5.1e6, D = 5, k1 = 1 / 5,
                         k2 = 1, q = 0.05,
                         r = 0.1, ur = 0.02, f1 = 1.0,
                         start_decline = 15,
                         end_decline = 22
                       ),
                       i0 = 8,
                       fsi = pars[["r"]] / (pars[["r"]] + pars[["ur"]]),
                       nsi = 1 - fsi,
                       state_0 = c(
                         S = nsi * (pars[["N"]] - i0),
                         E1 = 0.4 * nsi * i0,
                         E2 = 0.1 * nsi * i0,
                         I = 0.5 * nsi * i0,
                         Q = 0,
                         R = 0,
                         Sd = fsi * (pars[["N"]] - i0),
                         E1d = 0.4 * fsi * i0,
                         E2d = 0.1 * fsi * i0,
                         Id = 0.5 * fsi * i0,
                         Qd = 0,
                         Rd = 0
                       ),
                       save_state_predictions = FALSE,
                       delayScale = 9.85,
                       delayShape = 1.73,
                       ode_control = c(1e-6, 1e-6, 1e6),
                       daily_cases_omit = NULL,
                       ...) {
  obs_model <- match.arg(obs_model)
  obs_model <-
    if (obs_model == "Poisson") {
      0L
    } else if (obs_model == "NB2") {
      1L
    } else {
      2L
    }
  x_r <- pars

  sampFrac2_type <- match.arg(sampFrac2_type)
  n_sampFrac2 <-
    if (sampFrac2_type == "fixed") {
      0L
    } else if (sampFrac2_type == "estimated") {
      1L
    } else { # random walk:
      length(daily_cases) - sampled_fraction_day_change + 1L
    }

  if (!is.null(daily_tests)) {
    stopifnot(length(daily_cases) + forecast_days == length(daily_tests))
    if (min(daily_tests) == 0) {
      warning("Replacing 0 daily tests with 1.")
      daily_tests[daily_tests == 0] <- 1
    }
  }
  stopifnot(
    names(x_r) ==
      c("N", "D", "k1", "k2", "q", "r", "ur", "f1", "start_decline", "end_decline")
  )
  stopifnot(
    names(state_0) == c("S", "E1", "E2", "I", "Q", "R", "Sd", "E1d", "E2d", "Id", "Qd", "Rd")
  )

  days <- seq(1, length(daily_cases) + forecast_days)
  last_day_obs <- length(daily_cases)
  time <- seq(-30, max(days), time_increment)
  x_r <- c(x_r, if (!is.null(fixed_f_forecast)) fixed_f_forecast else 0)
  names(x_r)[length(x_r)] <- "fixed_f_forecast"
  x_r <- c(x_r, c("last_day_obs" = last_day_obs))
  x_r <- c(x_r, c("day_start_fixed_f_forecast" = day_start_fixed_f_forecast))

  # find the equivalent time of each day (end):
  get_time_id <- function(day, time) max(which(time <= day))
  time_day_id <- vapply(days, get_time_id, numeric(1), time = time)

  get_time_day_id0 <- function(day, time, days_back) {
    # go back `days_back` or to beginning if that's negative time:
    check <- time <= (day - days_back)
    if (sum(check) == 0L) {
      1L
    } else {
      max(which(check))
    }
  }
  # find the equivalent time of each day (start):
  time_day_id0 <- vapply(days, get_time_day_id0, numeric(1),
    time = time, days_back = days_back
  )

  if (is.null(sampled_fraction_vec)) {
    sampFrac <- ifelse(days < sampled_fraction_day_change,
      sampled_fraction1, sampled_fraction2)
  } else {
    stopifnot(length(sampled_fraction_vec) == length(days))
    sampFrac <- sampled_fraction_vec
  }

  beta_sd <- f2_prior[2]
  beta_mean <- f2_prior[1]
  beta_shape1 <- get_beta_params(beta_mean, beta_sd)$alpha
  beta_shape2 <- get_beta_params(beta_mean, beta_sd)$beta

  sampFrac2_beta_sd <- sampFrac2_prior[2]
  sampFrac2_beta_mean <- sampFrac2_prior[1]
  sampFrac2_beta_shape1 <- get_beta_params(sampFrac2_beta_mean, sampFrac2_beta_sd)$alpha
  sampFrac2_beta_shape2 <- get_beta_params(sampFrac2_beta_mean, sampFrac2_beta_sd)$beta

  dat_in_lik <- seq(1, last_day_obs)
  if (!is.null(daily_cases_omit)) {
    dat_in_lik <- dat_in_lik[-daily_cases_omit]
  }
  stan_data <- list(
    T = length(time),
    days = days,
    daily_cases = daily_cases,
    tests = if (is.null(daily_tests)) rep(log(1), length(days)) else daily_tests,
    N = length(days),
    y0 = state_0,
    t0 = min(time) - 0.000001,
    time = time,
    x_r = x_r,
    delayShape = delayShape,
    delayScale = delayScale,
    sampFrac = sampFrac,
    time_day_id = time_day_id,
    time_day_id0 = time_day_id0,
    R0_prior = R0_prior,
    phi_prior = phi_prior,
    f2_prior = c(beta_shape1, beta_shape2),
    sampFrac2_prior = c(sampFrac2_beta_shape1, sampFrac2_beta_shape2),
    day_inc_sampling = sampled_fraction_day_change,
    n_sampFrac2 = n_sampFrac2,
    rw_sigma = rw_sigma,
    priors_only = 0L,
    last_day_obs = last_day_obs,
    obs_model = obs_model,
    ode_control = ode_control,
    est_phi = if (obs_model %in% c(1L, 2L)) 1L else 0L,
    dat_in_lik = dat_in_lik,
    N_lik = length(dat_in_lik)
  )
  # map_estimate <- optimizing(
  #   seeiqr_model,
  #   data = stan_data
  # )
  initf <- function(stan_data) {
    R0 <- rlnorm(1, log(R0_prior[1]), R0_prior[2])
    f2 <- rbeta(
      1,
      get_beta_params(f2_prior[1], f2_prior[2])$alpha,
      get_beta_params(f2_prior[1], f2_prior[2])$beta
    )
    init <- list(R0 = R0, f2 = f2)
    init
  }
  pars_save <- c("R0", "f2", "phi", "lambda_d", "y_rep", "sampFrac2")
  if (save_state_predictions) pars_save <- c(pars_save, "y_hat")
  fit <- rstan::sampling(
    seeiqr_model,
    data = stan_data,
    iter = iter,
    chains = chains,
    init = function() initf(stan_data),
    seed = seed, # https://xkcd.com/221/
    pars = pars_save,
    ... = ...
  )
  post <- rstan::extract(fit)
  list(
    fit = fit, post = post, phi_prior = phi_prior, R0_prior = R0_prior,
    f2_prior = f2_prior, obs_model = obs_model, sampFrac = sampFrac, state_0 = state_0,
    daily_cases = daily_cases, daily_tests = daily_tests, days = days, time = time,
    last_day_obs = last_day_obs, pars = x_r, f2_prior_beta_shape1 = beta_shape1,
    f2_prior_beta_shape2 = beta_shape2, stan_data = stan_data
  )
}

get_beta_params <- function(mu, sd) {
  var <- sd^2
  alpha <- ((1 - mu) / var - 1 / mu) * mu^2
  beta <- alpha * (1 / mu - 1)
  list(alpha = alpha, beta = beta)
}
