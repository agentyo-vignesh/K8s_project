/**
 * Application shell: top bar, navigation drawer and the routed content area.
 *
 * Navigation items are filtered by role so a candidate sees only their schedule. That is presentation
 * only; the API enforces the same rules independently.
 */
import { useState } from 'react';
import {
  AppBar,
  Avatar,
  Box,
  Chip,
  Divider,
  Drawer,
  IconButton,
  List,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  Menu,
  MenuItem,
  Toolbar,
  Tooltip,
  Typography,
  useMediaQuery,
  useTheme,
} from '@mui/material';
import DashboardIcon from '@mui/icons-material/Dashboard';
import EventNoteIcon from '@mui/icons-material/EventNote';
import LogoutIcon from '@mui/icons-material/Logout';
import MenuIcon from '@mui/icons-material/Menu';
import PeopleIcon from '@mui/icons-material/People';
import PsychologyIcon from '@mui/icons-material/Psychology';
import { Outlet, useLocation, useNavigate } from 'react-router-dom';
import { config, isProduction } from '../config';
import { useAuth } from '../auth/AuthContext';

const DRAWER_WIDTH = 248;

const NAV_ITEMS = [
  { label: 'Dashboard', path: '/dashboard', icon: DashboardIcon, roles: ['ADMIN', 'INTERVIEWER'] },
  { label: 'Candidates', path: '/candidates', icon: PeopleIcon, roles: ['ADMIN', 'INTERVIEWER'] },
  { label: 'Interviews', path: '/interviews', icon: EventNoteIcon, roles: ['ADMIN', 'INTERVIEWER', 'CANDIDATE'] },
];

export function AppLayout() {
  const theme = useTheme();
  const isDesktop = useMediaQuery(theme.breakpoints.up('md'));
  const [drawerOpen, setDrawerOpen] = useState(false);
  const [menuAnchor, setMenuAnchor] = useState(null);
  const navigate = useNavigate();
  const location = useLocation();
  const { user, logout } = useAuth();

  const visibleItems = NAV_ITEMS.filter((item) => item.roles.includes(user?.role));

  const handleNavigate = (path) => {
    navigate(path);
    if (!isDesktop) {
      setDrawerOpen(false);
    }
  };

  const handleLogout = async () => {
    setMenuAnchor(null);
    await logout();
    navigate('/login', { replace: true });
  };

  const initials = (user?.fullName || user?.email || '?')
    .split(' ')
    .map((part) => part[0])
    .slice(0, 2)
    .join('')
    .toUpperCase();

  const drawerContent = (
    <Box sx={{ display: 'flex', flexDirection: 'column', height: '100%' }}>
      <Toolbar sx={{ gap: 1.5 }}>
        <PsychologyIcon color="primary" />
        <Typography variant="h6" noWrap>
          AI Interview
        </Typography>
      </Toolbar>
      <Divider />
      <List sx={{ flexGrow: 1, py: 1 }}>
        {visibleItems.map(({ label, path, icon: Icon }) => {
          // startsWith so a detail route keeps its section highlighted, but the exact check keeps
          // /interviews from matching when the user is on /interviews/new under a different section.
          const selected = location.pathname === path || location.pathname.startsWith(`${path}/`);
          return (
            <ListItemButton key={path} selected={selected} onClick={() => handleNavigate(path)}>
              <ListItemIcon>
                <Icon color={selected ? 'primary' : 'inherit'} />
              </ListItemIcon>
              <ListItemText primary={label} />
            </ListItemButton>
          );
        })}
      </List>
      <Divider />
      <Box sx={{ p: 2 }}>
        {/* Surfacing the environment prevents the classic "I was testing against prod" mistake. */}
        {!isProduction ? (
          <Chip size="small" color="warning" label={`env: ${config.appEnv}`} sx={{ mb: 1 }} />
        ) : null}
        <Typography variant="caption" color="text.secondary" display="block">
          {user?.fullName}
        </Typography>
        <Typography variant="caption" color="text.secondary" display="block">
          {user?.role}
        </Typography>
      </Box>
    </Box>
  );

  return (
    <Box sx={{ display: 'flex', minHeight: '100vh' }}>
      <AppBar
        position="fixed"
        color="inherit"
        sx={{
          width: { md: `calc(100% - ${DRAWER_WIDTH}px)` },
          ml: { md: `${DRAWER_WIDTH}px` },
          borderBottom: '1px solid #e3e7ee',
          boxShadow: 'none',
        }}
      >
        <Toolbar>
          <IconButton
            edge="start"
            onClick={() => setDrawerOpen(true)}
            sx={{ mr: 2, display: { md: 'none' } }}
            aria-label="Open navigation"
          >
            <MenuIcon />
          </IconButton>
          <Typography variant="h6" sx={{ flexGrow: 1 }} noWrap>
            AI Interview Platform
          </Typography>
          <Tooltip title={user?.email || ''}>
            <IconButton onClick={(event) => setMenuAnchor(event.currentTarget)} aria-label="Account menu">
              <Avatar sx={{ width: 34, height: 34, bgcolor: 'primary.main', fontSize: 14 }}>
                {initials}
              </Avatar>
            </IconButton>
          </Tooltip>
          <Menu anchorEl={menuAnchor} open={Boolean(menuAnchor)} onClose={() => setMenuAnchor(null)}>
            <MenuItem disabled sx={{ opacity: '1 !important' }}>
              <Box>
                <Typography variant="body2">{user?.fullName}</Typography>
                <Typography variant="caption" color="text.secondary">
                  {user?.email}
                </Typography>
              </Box>
            </MenuItem>
            <Divider />
            <MenuItem onClick={handleLogout}>
              <ListItemIcon>
                <LogoutIcon fontSize="small" />
              </ListItemIcon>
              Sign out
            </MenuItem>
          </Menu>
        </Toolbar>
      </AppBar>

      {/* Permanent on desktop, temporary on mobile: one nav definition, two behaviours. */}
      <Drawer
        variant={isDesktop ? 'permanent' : 'temporary'}
        open={isDesktop || drawerOpen}
        onClose={() => setDrawerOpen(false)}
        ModalProps={{ keepMounted: true }}
        sx={{
          width: DRAWER_WIDTH,
          flexShrink: 0,
          '& .MuiDrawer-paper': { width: DRAWER_WIDTH, boxSizing: 'border-box' },
        }}
      >
        {drawerContent}
      </Drawer>

      <Box
        component="main"
        sx={{
          flexGrow: 1,
          width: { md: `calc(100% - ${DRAWER_WIDTH}px)` },
          p: { xs: 2, md: 3 },
          mt: 8,
          minWidth: 0,
        }}
      >
        <Outlet />
      </Box>
    </Box>
  );
}
