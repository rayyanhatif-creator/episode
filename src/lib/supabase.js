import { createClient } from '@supabase/supabase-js';

// These are public client-side values (URL + publishable key), not service-role secrets.
// Vite environment variables can still override them for other deployment environments.
const url = import.meta.env.VITE_SUPABASE_URL || 'https://daqtkhhlqlkpypffecel.supabase.co';
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY || 'sb_publishable_mwiKjxLYtMCXwZ_ZdC7TLA_6Gz4GbiD';

export const isSupabaseConfigured = Boolean(url && anonKey);
export const supabase = isSupabaseConfigured ? createClient(url, anonKey, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true },
  realtime: { params: { eventsPerSecond: 5 } }
}) : null;
