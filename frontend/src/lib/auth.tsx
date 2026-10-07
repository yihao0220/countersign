import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import { useQueryClient } from '@tanstack/react-query'
import { Navigate, useLocation } from 'react-router-dom'
import { useLang } from '../i18n'

export interface User { id: string; name: string; email: string }
type Auth = {
  user: User | null; loading: boolean; error: string
  refresh: () => Promise<void>; signedIn: (user: User) => void; logout: () => Promise<void>
}
const AuthContext = createContext<Auth | null>(null)
export const SESSION_EXPIRED = 'countersign-session-expired'

export async function authRequest(path: string, data?: Record<string, string>) {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 12_000)
  try {
    const response = await fetch(path, {
      method: data === undefined ? 'GET' : 'POST', credentials: 'same-origin',
      headers: data === undefined ? {} : { 'Content-Type': 'application/json' },
      body: data === undefined ? undefined : JSON.stringify(data), signal: controller.signal,
    })
    const result = await response.json()
    return { response, result }
  } finally { clearTimeout(timer) }
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const qc = useQueryClient()
  const revision = useRef(0)
  const setAccount = useCallback((next: User | null) => {
    revision.current++
    void qc.cancelQueries()
    qc.clear()
    setUser(next)
    setError('')
    setLoading(false)
  }, [qc])
  const refresh = useCallback(async () => {
    const current = revision.current
    try {
      const { response, result } = await authRequest('/api/me')
      if (revision.current !== current) return
      if (response.ok) { setUser(result.user); setError('') }
      else if (response.status === 401) { setAccount(null) }
      else { setError('登录服务暂不可用，请稍后重试。') }
    } catch {
      if (revision.current === current) setError('无法连接登录服务，请稍后重试。')
    } finally { if (revision.current === current) setLoading(false) }
  }, [setAccount])
  useEffect(() => {
    void refresh()
    const interval = setInterval(() => { if (document.visibilityState === 'visible') void refresh() }, 60_000)
    const expired = () => setAccount(null)
    const visible = () => { if (document.visibilityState === 'visible') void refresh() }
    window.addEventListener(SESSION_EXPIRED, expired)
    document.addEventListener('visibilitychange', visible)
    return () => {
      clearInterval(interval)
      window.removeEventListener(SESSION_EXPIRED, expired)
      document.removeEventListener('visibilitychange', visible)
    }
  }, [refresh, setAccount])
  const logout = async () => {
    const { response } = await authRequest('/api/logout', {})
    if (!response.ok) throw new Error('退出未完成，请重试。')
    setAccount(null)
  }
  return <AuthContext.Provider value={{ user, loading, error, refresh, signedIn: setAccount, logout }}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const ctx = useContext(AuthContext)
  if (!ctx) throw new Error('useAuth outside AuthProvider')
  return ctx
}

export function workspaceDestination(value: string | null) {
  if (!value) return '/inbox'
  return /^\/(inbox|ledger|controls|bounty)(?:\?[^#]*)?$/.test(value) ? value : '/inbox'
}

export function RequireAuth({ children }: { children: ReactNode }) {
  const { user, loading, error, refresh } = useAuth()
  const { tr } = useLang()
  const loc = useLocation()
  if (loading) return <div className="session-state" role="status">{tr('Checking your session…', '正在检查登录状态…')}</div>
  if (error) return <main className="session-state"><p role="alert">{error}</p><button className="btn btn-ink mt-4" onClick={() => void refresh()}>{tr('Retry', '重试')}</button></main>
  if (!user) return <Navigate to={`/login?next=${encodeURIComponent(loc.pathname + loc.search)}`} replace />
  return <>{children}</>
}
