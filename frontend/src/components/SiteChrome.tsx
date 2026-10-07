import { useState } from 'react'
import { Link, NavLink, useNavigate } from 'react-router-dom'
import { useAuth } from '../lib/auth'
import { useLang } from '../i18n'
import { LangSwitch, ThemeSwitch } from './Toggles'

export function SiteHeader({ workspace = false, network, mock = false }: { workspace?: boolean; network?: string; mock?: boolean }) {
  const { user, logout } = useAuth()
  const { tr } = useLang()
  const navigate = useNavigate()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  async function signOut() {
    setBusy(true); setError('')
    try { await logout(); navigate('/login', { replace: true }) }
    catch { setError(tr('Could not sign out. Please retry.', '退出未完成，请重试。')) }
    finally { setBusy(false) }
  }
  const links = workspace
    ? [['/inbox', tr('Inbox', '发票工作台')], ['/ledger', tr('Ledger', '账本')], ['/controls', tr('Controls', '管理控制台')], ['/bounty', tr('Challenge', '挑战防线')]]
    : [['/?section=workflow', tr('How it works', '工作流程')], ['/?section=stack', tr('Building blocks', '核心能力')], ['/inbox', tr('Workspace', '工作台')]]
  return <header className="site-header">
    <div className="site-topbar">
      <Link to="/" className="site-brand" aria-label="Countersign 首页">Countersign<span className="brand-point">.</span></Link>
      <div className="site-actions">
        <LangSwitch /><ThemeSwitch />
        {user ? <>
          <span className="account-label" title={user.email}>{user.name}</span>
          {workspace ? <button type="button" className="site-button secondary" disabled={busy} onClick={() => void signOut()}>{busy ? tr('Signing out…', '正在退出…') : tr('Sign out', '退出登录')}</button>
            : <Link className="site-button" to="/inbox">{tr('Open workspace', '进入工作台')} <span aria-hidden>→</span></Link>}
        </> : <>
          <Link className="site-signin" to="/login">{tr('Sign in', '登录')}</Link>
          <Link className="site-button" to="/signup">{tr('Get started', '创建账户')} <span aria-hidden>→</span></Link>
        </>}
      </div>
    </div>
    <div className="site-subbar">
      <nav aria-label={tr('Main navigation', '主导航')}>
        {links.map(([to, label]) => <NavLink key={to} to={to} className={({ isActive }) => workspace && isActive ? 'is-active' : ''}>{label}</NavLink>)}
      </nav>
      {workspace && <span className="site-network"><span className="status-dot" />{mock ? tr('Simulated workspace', '模拟工作台') : network}</span>}
    </div>
    {error && <p className="site-error" role="alert">{error}</p>}
  </header>
}

export function SiteFooter() {
  const { tr } = useLang()
  return <footer className="site-footer"><Link className="site-brand" to="/">Countersign<span className="brand-point">.</span></Link><span>© 2026 Countersign · {tr('Your rules. Every payment.', '每笔付款，遵循你的规则。')}</span><Link to="/inbox">{tr('Open workspace', '进入工作台')} →</Link></footer>
}
