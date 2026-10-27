import { createContext, useContext, type ReactNode } from 'react';
import { InteractionRequiredAuthError, PublicClientApplication } from '@azure/msal-browser';
import { MsalProvider, useMsal } from '@azure/msal-react';
import type { RuntimeConfig } from './config';

// Two modes:
//  - Entra ID configured (phase 6): MSAL signs the user in (auth code + PKCE) and gets access tokens for the API scope.
//  - Not configured: no sign-in; the API's developer bypass treats every call as a local admin.

export interface AuthState {
  enabled: boolean;
  signedIn: boolean;
  userName: string | null;
  signIn: () => Promise<void>;
  signOut: () => Promise<void>;
}

const anonymous: AuthState = {
  enabled: false,
  signedIn: true,
  userName: 'Local Developer',
  signIn: async () => {},
  signOut: async () => {},
};

const AuthContext = createContext<AuthState>(anonymous);
export const useAuth = () => useContext(AuthContext);

let tokenProvider: () => Promise<string | null> = async () => null;
let loginScopes: string[] = [];

/** Bearer token for the API, or null when auth is off or nobody is signed in. */
export const getAccessToken = () => tokenProvider();

export async function createMsal(cfg: RuntimeConfig): Promise<PublicClientApplication | null> {
  const { clientId, tenantId, apiScope } = cfg.entra;
  if (!clientId) return null;
  loginScopes = [apiScope];

  const msal = new PublicClientApplication({
    auth: {
      clientId,
      authority: `https://login.microsoftonline.com/${tenantId || 'organizations'}`,
      redirectUri: window.location.origin,
    },
    cache: { cacheLocation: 'sessionStorage' },
  });
  await msal.initialize();

  const redirect = await msal.handleRedirectPromise();
  const account = redirect?.account ?? msal.getActiveAccount() ?? msal.getAllAccounts()[0];
  if (account) msal.setActiveAccount(account);

  tokenProvider = async () => {
    const active = msal.getActiveAccount();
    if (!active) return null;
    try {
      return (await msal.acquireTokenSilent({ scopes: [apiScope], account: active })).accessToken;
    } catch (error) {
      if (error instanceof InteractionRequiredAuthError) {
        await msal.acquireTokenRedirect({ scopes: [apiScope], account: active });
      }
      throw error;
    }
  };

  return msal;
}

export function AuthProvider({ msal, children }: { msal: PublicClientApplication | null; children: ReactNode }) {
  if (!msal) return <AuthContext.Provider value={anonymous}>{children}</AuthContext.Provider>;
  return (
    <MsalProvider instance={msal}>
      <MsalAuthBridge>{children}</MsalAuthBridge>
    </MsalProvider>
  );
}

function MsalAuthBridge({ children }: { children: ReactNode }) {
  const { instance, accounts } = useMsal();
  const account = instance.getActiveAccount() ?? accounts[0] ?? null;

  const state: AuthState = {
    enabled: true,
    signedIn: account !== null,
    userName: account?.name ?? account?.username ?? null,
    // Asking for the API scope at sign-in gets consent for it up front.
    signIn: () => instance.loginRedirect({ scopes: loginScopes }),
    signOut: () => instance.logoutRedirect(),
  };
  return <AuthContext.Provider value={state}>{children}</AuthContext.Provider>;
}
