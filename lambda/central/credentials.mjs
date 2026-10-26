// Credentials for every AWS client in this lambda.
//
// On AWS Lambda and in the local runner the static key in .env is used
// (ACCESS_KEY_ID / SECRET_ACCESS_KEY, optionally SESSION_TOKEN). When no key
// is set the SDK's default chain is used instead — register.mjs relies on
// that to fall back to the `aws login` session of the operator's shell.
export function credentialsFromEnv() {
  const { ACCESS_KEY_ID, SECRET_ACCESS_KEY, SESSION_TOKEN } = process.env;
  if (!ACCESS_KEY_ID || !SECRET_ACCESS_KEY) return undefined;
  return {
    accessKeyId: ACCESS_KEY_ID,
    secretAccessKey: SECRET_ACCESS_KEY,
    ...(SESSION_TOKEN ? { sessionToken: SESSION_TOKEN } : {}),
  };
}
