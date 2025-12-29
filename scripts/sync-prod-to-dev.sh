#!/bin/bash

# Sync BazaarGhost production database to development
# Usage: PROD_DB_PASSWORD=xxx DEV_DB_PASSWORD=yyy ./scripts/sync-prod-to-dev.sh

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check required environment variables
if [ -z "$PROD_DB_PASSWORD" ]; then
    echo -e "${RED}Error: PROD_DB_PASSWORD environment variable is not set${NC}"
    echo "Usage: PROD_DB_PASSWORD=xxx DEV_DB_PASSWORD=yyy $0"
    exit 1
fi

if [ -z "$DEV_DB_PASSWORD" ]; then
    echo -e "${RED}Error: DEV_DB_PASSWORD environment variable is not set${NC}"
    echo "Usage: PROD_DB_PASSWORD=xxx DEV_DB_PASSWORD=yyy $0"
    exit 1
fi

# Database connection strings
# Using transaction mode pooler (port 6543) for IPv4 compatibility
PROD_DB_URL="postgresql://postgres.dzklnkhayqmwldnjxywr:${PROD_DB_PASSWORD}@aws-1-us-east-2.pooler.supabase.com:6543/postgres"
DEV_DB_URL="postgresql://postgres.lcqtbxpdiskkssvspnku:${DEV_DB_PASSWORD}@aws-0-us-west-2.pooler.supabase.com:6543/postgres"

echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}     BazaarGhost Production → Development Database Sync${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo
echo -e "${RED}⚠️  WARNING: This will completely replace the dev database with prod data!${NC}"
echo -e "    All existing data in the dev database will be lost."
echo
read -p "Are you sure you want to continue? Type 'yes' to proceed: " -r
echo
if [[ ! $REPLY == "yes" ]]; then
    echo "Sync cancelled."
    exit 0
fi

# Create backup directory with timestamp
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="supabase/backup-prod-${TIMESTAMP}"
mkdir -p "$BACKUP_DIR"

echo -e "${BLUE}📁 Backup directory: ${BACKUP_DIR}${NC}"
echo

# Step 1: Backup production database
echo -e "${GREEN}Step 1/4: Backing up production database...${NC}"
echo "  → Dumping roles..."
supabase db dump --db-url "$PROD_DB_URL" -f "$BACKUP_DIR/roles.sql" --role-only

echo "  → Dumping schema..."
supabase db dump --db-url "$PROD_DB_URL" -f "$BACKUP_DIR/schema.sql"

echo "  → Dumping data (this may take a few minutes)..."
supabase db dump --db-url "$PROD_DB_URL" -f "$BACKUP_DIR/data.sql" --use-copy --data-only

# Step 2: Clean problematic statements
echo -e "${GREEN}Step 2/4: Cleaning SQL files...${NC}"
# Remove problematic postgres role grants
sed -i.bak '/GRANT "postgres" TO "cli_login_postgres"/d' "$BACKUP_DIR/roles.sql"

# Remove supabase_admin ownership if present (though it shouldn't be in dumps)
if grep -q "OWNER TO.*supabase_admin" "$BACKUP_DIR/schema.sql"; then
    echo "  → Removing supabase_admin ownership statements..."
    sed -i.bak 's/OWNER TO "supabase_admin"/-- OWNER TO "supabase_admin"/g' "$BACKUP_DIR/schema.sql"
fi

# Step 3: Check database size
echo -e "${GREEN}Step 3/4: Checking database size...${NC}"
DATA_SIZE=$(du -sh "$BACKUP_DIR/data.sql" | cut -f1)
echo -e "  → Data file size: ${BLUE}${DATA_SIZE}${NC}"

# Warn if approaching free tier limit
DATA_SIZE_MB=$(du -sm "$BACKUP_DIR/data.sql" | cut -f1)
if [ "$DATA_SIZE_MB" -gt 400 ]; then
    echo -e "${YELLOW}  ⚠️  Warning: Data size (${DATA_SIZE_MB}MB) approaching free tier limit (500MB)${NC}"
fi

# Step 4: Restore to dev database
echo -e "${GREEN}Step 4/4: Restoring to dev database...${NC}"
echo "  → Executing restore (this may take a few minutes)..."

# Run restore, capturing output
if psql \
    --single-transaction \
    --variable ON_ERROR_STOP=1 \
    --file "$BACKUP_DIR/roles.sql" \
    --file "$BACKUP_DIR/schema.sql" \
    --command 'SET session_replication_role = replica' \
    --file "$BACKUP_DIR/data.sql" \
    --dbname "$DEV_DB_URL" 2>&1 | tee "$BACKUP_DIR/restore.log" | grep -E "ERROR:|WARNING:" | head -20; then
    echo
    echo -e "${GREEN}✅ Database sync completed successfully!${NC}"
    echo -e "   Backup saved to: ${BLUE}${BACKUP_DIR}${NC}"
    echo -e "   Full restore log: ${BLUE}${BACKUP_DIR}/restore.log${NC}"
else
    RESTORE_EXIT_CODE=$?
    echo
    echo -e "${RED}❌ Restore encountered errors (exit code: $RESTORE_EXIT_CODE)${NC}"
    echo -e "   Check the log file: ${BLUE}${BACKUP_DIR}/restore.log${NC}"
    echo
    echo "Common errors and solutions:"
    echo "  • 'role already exists' - Normal, can be ignored"
    echo "  • 'schema already exists' - Normal for auth/storage schemas"
    echo "  • 'permission denied' - May need to comment out problematic lines"
    exit $RESTORE_EXIT_CODE
fi

# Step 5: Summary
echo
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN} Sync Summary${NC}"
echo -e "${YELLOW}════════════════════════════════════════════════════════════════${NC}"
echo "  Production URL: https://dzklnkhayqmwldnjxywr.supabase.co"
echo "  Development URL: https://lcqtbxpdiskkssvspnku.supabase.co"
echo "  Backup location: ${BACKUP_DIR}"
echo "  Data size: ${DATA_SIZE}"
echo
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Deploy Edge Functions to dev (if needed):"
echo "     supabase functions deploy --project-ref lcqtbxpdiskkssvspnku"
echo "  2. Test your dev environment"
echo "  3. Update local .env to use dev credentials"
echo
echo -e "${GREEN}Done! 🎉${NC}"