import { lazy, Suspense } from 'react'
import { HashRouter, Navigate, Route, Routes } from 'react-router-dom'
import { QueryCache, QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { ServerBanner } from './components/ServerBanner'
import { isServerProblem, markServer } from './lib/net'
import { LangProvider } from './i18n'
import BountyPage from './pages/Bounty'
import LandingPage from './pages/Landing'
import AuthPage from './pages/Auth'
import { AuthProvider, RequireAuth } from './lib/auth'

// The bounty page is what phones open from the QR code, so it ships in the main bundle.
// Everything else loads on demand; Controls carries wagmi and viem.
const LedgerPage = lazy(() => import('./pages/Ledger'))
const InboxPage = lazy(() => import('./pages/Inbox'))
const ControlsPage = lazy(() => import('./pages/Controls'))

const queryClient = new QueryClient({
  queryCache: new QueryCache({
    onError: (err) => isServerProblem(err) && markServer(false),
    onSuccess: () => markServer(true),
  }),
  defaultOptions: {
    queries: { retry: 1, refetchOnWindowFocus: false, staleTime: 1000 },
  },
})

function Loading() {
  return <div className="mx-auto mt-24 h-2 w-40 animate-pulse rounded-full bg-paper2" aria-label="Loading" />
}

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <LangProvider>
        <ServerBanner />
        {/* hash routes: the server never needs an SPA fallback, and links survive WeChat's in-app browser */}
        <HashRouter>
          <AuthProvider>
          <Suspense fallback={<Loading />}>
            <Routes>
              <Route path="/" element={<LandingPage />} />
              <Route path="/login" element={<AuthPage />} />
              <Route path="/signup" element={<AuthPage register />} />
              <Route path="/bounty" element={<RequireAuth><BountyPage /></RequireAuth>} />
              <Route path="/ledger" element={<RequireAuth><LedgerPage /></RequireAuth>} />
              <Route path="/inbox" element={<RequireAuth><InboxPage /></RequireAuth>} />
              <Route path="/controls" element={<RequireAuth><ControlsPage /></RequireAuth>} />
              <Route path="*" element={<Navigate to="/" replace />} />
            </Routes>
          </Suspense>
          </AuthProvider>
        </HashRouter>
      </LangProvider>
    </QueryClientProvider>
  )
}
