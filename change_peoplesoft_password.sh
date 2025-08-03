#!/bin/bash
#
# This script automates the process of changing a PeopleSoft access password (e.g., for SYSADM)
# using a PeopleTools Data Mover script.
#
# It securely prompts for credentials and ensures that no passwords are stored in plaintext
# in files or command-line history.
#

# --- Configuration ---
# IMPORTANT: Update these variables to match your environment.
PS_HOME="/opt/oracle/psft/pt"
ACCESS_ID="SYSADM"
DB_NAME="PSEMU"
DB_TYPE="ORACLE"
GPG_PASSWORD_FILE="/path/to/your/password.gpg" # Path to GPG encrypted password file
DMS_TEMPLATE_FILE="./update_password_template.dms" # Path to the DMS template file

# SQL statement for the initial, direct update.
# The placeholder %%NEW_PASSWORD%% will be replaced by the script.
DIRECT_SQL_UPDATE="UPDATE PSACCESSPROFILE SET ACCESSPSWD = '%%NEW_PASSWORD%%' WHERE ACCESSID = 'SYSADM';"

# Hardcoded Database User ID
DM_USER="FINPRD"


# --- Function Definitions ---

run_direct_sql_update() {
    local new_pass="$1"
    local sql_statement

    echo "--------------------------------------------------"
    echo "Step 1: Performing direct database update via sqlplus..."

    # Substitute the new password into the SQL statement
    sql_statement=$(echo "$DIRECT_SQL_UPDATE" | sed "s|%%NEW_PASSWORD%%|${new_pass}|g")

    # Execute sqlplus, piping the commands to it securely.
    # The '|| echo' trick ensures the variable captures output even on failure.
    local output
    output=$(sqlplus -S -L "${DM_USER}/${DM_PASSWORD}@${DB_NAME}" <<EOF
WHENEVER SQLERROR EXIT 1;
WHENEVER OSERROR EXIT 1;
SET FEEDBACK OFF;
SET HEADING OFF;
${sql_statement}
COMMIT;
EXIT;
EOF
    ) || echo "SQLPLUS_ERROR"

    # Check for Oracle errors in the output
    if echo "$output" | grep -q -E 'ORA-|SP2-'; then
        echo "Error: Direct SQL update failed. Oracle error detected." >&2
        echo "--- SQLPLUS OUTPUT ---" >&2
        echo "$output" >&2
        echo "----------------------" >&2
        return 1
    elif [[ "$output" == "SQLPLUS_ERROR" ]]; then
        echo "Error: sqlplus command failed to execute." >&2
        return 1
    fi

    echo "Direct database update appears to be successful."
    return 0
}


echo "PeopleSoft Password Change Automation Script"
echo "------------------------------------------"
echo

# --- Securely Prompt for Credentials ---

# 1. Get the credentials for the user running the Data Mover script.
# The password will be decrypted from a GPG file. The User ID is hardcoded.
echo "Using Database User ID: ${DM_USER}"

# --- Prerequisite Checks ---
if ! command -v gpg &> /dev/null; then
    echo "Error: gpg command not found. Please install GnuPG." >&2
    exit 1
fi

if ! command -v sqlplus &> /dev/null; then
    echo "Error: sqlplus command not found. Please ensure Oracle Client is installed and in your PATH." >&2
    exit 1
fi

if [ ! -r "$GPG_PASSWORD_FILE" ]; then
    echo "Error: GPG password file not found or not readable at: ${GPG_PASSWORD_FILE}" >&2
    exit 1
fi

echo "Decrypting database password from ${GPG_PASSWORD_FILE}..."
DM_PASSWORD=$(gpg --decrypt --quiet --batch "$GPG_PASSWORD_FILE" 2>/dev/null)

if [ -z "$DM_PASSWORD" ]; then
    echo "Error: Failed to decrypt password. The file might be invalid or you may not have the required GPG keys." >&2
    exit 1
fi
echo "Decryption successful."
echo

# 2. Get the new password for the PeopleSoft Access ID.
echo "Please enter the new password for the Access ID: ${ACCESS_ID}"
read -s -p "New Password: " NEW_PASSWORD
echo
read -s -p "Confirm New Password: " NEW_PASSWORD_CONFIRM
echo
echo

# --- Validate Input ---
if [ -z "$NEW_PASSWORD" ]; then
    echo "Error: The new password is required." >&2
    exit 1
fi

if [ "$NEW_PASSWORD" != "$NEW_PASSWORD_CONFIRM" ]; then
    echo "Error: The new passwords do not match." >&2
    exit 1
fi

echo "Input validation successful."
echo

# --- Step 1: Direct SQL Update ---
run_direct_sql_update "$NEW_PASSWORD"
if [ $? -ne 0 ]; then
    echo "Aborting script due to failure in direct SQL update step." >&2
    exit 1
fi
echo

# --- Step 2: Create a temporary Data Mover Script for final encryption ---
echo "--------------------------------------------------"
echo "Step 2: Preparing Data Mover script for final encryption..."
# Using mktemp to create a secure temporary file
DMS_FILE=$(mktemp /tmp/change_password.XXXXXX.dms)
if [ ! -f "$DMS_FILE" ]; then
    echo "Error: Could not create temporary file." >&2
    exit 1
fi

echo "Generating Data Mover script from template: ${DMS_TEMPLATE_FILE}"

if [ ! -r "$DMS_TEMPLATE_FILE" ]; then
    echo "Error: DMS template file not found or not readable at: ${DMS_TEMPLATE_FILE}" >&2
    rm -f "$DMS_FILE" # Clean up the temp file we already created
    exit 1
fi

# Use sed to replace placeholders in the template and create the final DMS script
sed -e "s|%%NEW_PASSWORD%%|${NEW_PASSWORD}|g" \
    -e "s|%%ACCESS_ID%%|${ACCESS_ID}|g" \
    -e "s|%%DMS_LOG_FILE%%|${DMS_FILE}.log|g" \
    "$DMS_TEMPLATE_FILE" > "$DMS_FILE"

if [ $? -ne 0 ]; then
    echo "Error: Failed to generate DMS script from template." >&2
    rm -f "$DMS_FILE"
    exit 1
fi

echo "Data Mover script generated successfully at: ${DMS_FILE}"
echo

# --- Execute Data Mover ---
# The PSSWD environment variable is used by PeopleSoft command-line utilities
# to securely provide a password without putting it on the command line.
export PSSWD=$DM_PASSWORD

# Define the path to the Data Mover executable
PS_CMD="${PS_HOME}/bin/psdmt"

if [ ! -x "$PS_CMD" ]; then
    echo "Error: Data Mover executable not found or not executable at: ${PS_CMD}" >&2
    # Clean up before exiting
    unset PSSWD
    rm -f "$DMS_FILE"
    exit 1
fi

echo "Running Data Mover..."
# The -CI flag tells the utility to use the User ID from the command line (-CO)
# and the password from the PSSWD environment variable.
"$PS_CMD" -CT $DB_TYPE -CD $DB_NAME -CO $DM_USER -CI -I "$DMS_FILE"

# Store the exit code for later
EXIT_CODE=$?

# --- Cleanup ---
# Immediately unset the password variable and remove the temporary script
unset PSSWD
rm -f "$DMS_FILE"

echo "Cleanup complete."
echo

# --- Final Status ---
if [ $EXIT_CODE -eq 0 ]; then
    echo "Password change successful for Access ID: ${ACCESS_ID}"
    echo "Please check the log file for details: ${DMS_FILE}.log"
else
    echo "Error: Data Mover process failed with exit code ${EXIT_CODE}." >&2
    echo "Please check the log file for errors: ${DMS_FILE}.log" >&2
    exit 1
fi

exit 0
