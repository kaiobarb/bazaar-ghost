-- Better Auth 1.7.3 native D1 schema, with application-owned integrity constraints.
-- Core DATE columns store ISO-8601 UTC strings; application INTEGER times use Unix
-- milliseconds. The native adapter does not implement transactions.
CREATE TABLE app_users (
  id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, email TEXT NOT NULL UNIQUE,
  emailVerified INTEGER NOT NULL CHECK(emailVerified IN(0,1)), image TEXT,
  createdAt DATE NOT NULL, updatedAt DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'active' CHECK(status IN('active','suspended')),
  registeredAt INTEGER
);
CREATE TABLE user_sessions (
  id TEXT PRIMARY KEY NOT NULL, expiresAt DATE NOT NULL, token TEXT NOT NULL UNIQUE,
  createdAt DATE NOT NULL, updatedAt DATE NOT NULL, ipAddress TEXT, userAgent TEXT,
  userId TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE
);
CREATE TABLE user_accounts (
  id TEXT PRIMARY KEY NOT NULL, accountId TEXT NOT NULL,
  providerId TEXT NOT NULL CHECK(providerId IN('discord','twitch')),
  userId TEXT NOT NULL REFERENCES app_users(id) ON DELETE CASCADE,
  accessToken TEXT CHECK(accessToken IS NULL), refreshToken TEXT CHECK(refreshToken IS NULL),
  idToken TEXT CHECK(idToken IS NULL), accessTokenExpiresAt DATE, refreshTokenExpiresAt DATE,
  scope TEXT, password TEXT CHECK(password IS NULL), createdAt DATE NOT NULL, updatedAt DATE NOT NULL,
  linkSessionId TEXT,
  UNIQUE(providerId,accountId)
);
CREATE TABLE auth_verifications (
  id TEXT PRIMARY KEY NOT NULL, identifier TEXT NOT NULL, value TEXT NOT NULL,
  expiresAt DATE NOT NULL, createdAt DATE NOT NULL, updatedAt DATE NOT NULL
);
CREATE INDEX user_sessions_userId_idx ON user_sessions(userId);
CREATE INDEX user_sessions_expiresAt_idx ON user_sessions(expiresAt);
CREATE INDEX user_accounts_userId_idx ON user_accounts(userId);
CREATE INDEX auth_verifications_identifier_idx ON auth_verifications(identifier);
CREATE INDEX auth_verifications_expiresAt_idx ON auth_verifications(expiresAt);
CREATE INDEX app_users_unregistered_idx ON app_users(createdAt) WHERE registeredAt IS NULL;

-- The outer flow supplements the library's signed browser cookie with atomic consumption
-- and binds the provider and original linking session. Only SHA-256 state digests live here.
CREATE TABLE auth_flows (
  stateHash TEXT PRIMARY KEY NOT NULL,
  provider TEXT NOT NULL CHECK(provider IN('discord','twitch')),
  linkUserId TEXT REFERENCES app_users(id) ON DELETE CASCADE,
  linkSessionId TEXT REFERENCES user_sessions(id) ON DELETE CASCADE,
  expiresAt INTEGER NOT NULL, consumedAt INTEGER,
  CHECK((linkUserId IS NULL)=(linkSessionId IS NULL))
);
CREATE INDEX auth_flows_expiresAt_idx ON auth_flows(expiresAt);
CREATE TABLE auth_rate_limits(key TEXT PRIMARY KEY NOT NULL, count INTEGER NOT NULL, expiresAt INTEGER NOT NULL);
CREATE INDEX auth_rate_limits_expiresAt_idx ON auth_rate_limits(expiresAt);

CREATE TRIGGER auth_account_create_guard BEFORE INSERT ON user_accounts BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM app_users u WHERE u.id=NEW.userId AND u.status='active'
    AND ((u.registeredAt IS NULL AND NEW.linkSessionId IS NULL AND NOT EXISTS(SELECT 1 FROM user_accounts a WHERE a.userId=u.id))
      OR EXISTS(SELECT 1 FROM user_sessions s WHERE s.id=NEW.linkSessionId AND s.userId=u.id
        AND s.expiresAt>strftime('%Y-%m-%dT%H:%M:%fZ','now')
        AND s.createdAt>strftime('%Y-%m-%dT%H:%M:%fZ','now','-300 seconds'))))
    THEN RAISE(ABORT,'Invalid account registration or link session') END;
END;
CREATE TRIGGER auth_account_registered AFTER INSERT ON user_accounts BEGIN
  UPDATE app_users SET registeredAt=COALESCE(registeredAt,CAST(unixepoch('subsec')*1000 AS INTEGER)) WHERE id=NEW.userId;
END;
CREATE TRIGGER auth_account_identity_immutable BEFORE UPDATE ON user_accounts BEGIN
  SELECT CASE WHEN NEW.userId!=OLD.userId OR NEW.providerId!=OLD.providerId OR NEW.accountId!=OLD.accountId
    OR NOT EXISTS(SELECT 1 FROM app_users WHERE id=NEW.userId AND status='active')
    THEN RAISE(ABORT,'Invalid account update') END;
END;
CREATE TRIGGER auth_session_create_guard BEFORE INSERT ON user_sessions BEGIN
  SELECT CASE WHEN NOT EXISTS(SELECT 1 FROM app_users u WHERE u.id=NEW.userId AND u.status='active'
    AND u.registeredAt IS NOT NULL AND EXISTS(SELECT 1 FROM user_accounts a WHERE a.userId=u.id))
    THEN RAISE(ABORT,'User cannot sign in') END;
END;
CREATE TRIGGER auth_suspension_revoke AFTER UPDATE OF status ON app_users WHEN NEW.status!='active' BEGIN
  DELETE FROM user_sessions WHERE userId=NEW.id;
END;
