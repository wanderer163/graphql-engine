import type { CloudCliEnv, EnvVars } from '@/Globals';

export type ProConsoleEnv = {
  consoleMode: EnvVars['consoleMode'];
  consoleType?: EnvVars['consoleType'];
  pro?: CloudCliEnv['pro'];
};

export const isProConsole = (env: ProConsoleEnv) => {
  if (
    env.consoleMode === 'server' &&
    (env.consoleType === 'cloud' ||
      env.consoleType === 'pro' ||
      env.consoleType === 'pro-lite')
  ) {
    return true;
  }

  if (env.consoleMode === 'cli' && env.pro === true) {
    return true;
  }

  return false;
};

export const isMonitoringTabSupportedEnvironment = (env: ProConsoleEnv) => {
  // pro-lite and OSS environments won't have access to metrics server
  if (env.consoleMode === 'server')
    return env.consoleType === 'cloud' || env.consoleType === 'pro';
  // cloud and current self hosted setup will have pro:true
  else if (env.consoleMode === 'cli') return env.pro === true;

  // there should not be any other console modes
  throw new Error(`Invalid consoleMode:  ${env.consoleMode}`);
};

export const isEnvironmentSupportMultiTenantConnectionPooling = (
  env: ProConsoleEnv
) => {
  if (env.consoleMode === 'server') return env.consoleType === 'cloud';
  // cloud and current self hosted setup will have pro:true
  // FIX ME : currently in CLI mode there is no way to differentiate cloud and pro mode
  // This can be added once the CLI adds support of consoleType in the env vars provided to console.
  else if (env.consoleMode === 'cli') return env.pro === true;

  // there should not be any other console modes
  throw new Error(`Invalid consoleMode:  ${env.consoleMode}`);
};
