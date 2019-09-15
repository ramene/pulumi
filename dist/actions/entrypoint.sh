#!/bin/bash
# This is an entrypoint for our Docker image that does some minimal bootstrapping before executing.

# set -e
set -e

# If the PULUMI_CI variable is set, we'll do some extra things to make common tasks easier.
if [ ! -z "$PULUMI_CI" ]; then
    # Capture the PWD before we go and potentially change it.
    ROOT=$(pwd)

    # If the root of the Pulumi project isn't the root of the repo, CD into it.
    if [ ! -z "$PULUMI_ROOT" ]; then
       cd $PULUMI_ROOT
    fi

    # Detect the CI system and configure variables so that we get good Pulumi workflow and GitHub App support.
    if [ ! -z "$GITHUB_WORKFLOW" ]; then
        export PULUMI_CI_SYSTEM="GitHub"
        export PULUMI_CI_BUILD_ID=
        export PULUMI_CI_BUILD_TYPE=
        export PULUMI_CI_BUILD_URL=
        export PULUMI_CI_PULL_REQUEST_SHA="$GITHUB_SHA"

        # For PR events, we want to take the ref of the target branch, not the current. This ensures, for
        # instance, that a PR for a topic branch merging into `master` will use the `master` branch as the
        # target for a preview. Note that for push events, we of course want to use the actual branch.
        if [ "$PULUMI_CI" = "pr" ]; then
            # Not all PR events warrant running a preview. Many of them pertain to changes in assignments and
            # ownership, but we only want to run the preview if the action is "opened", "edited", or "synchronize".
            PR_ACTION=$(jq -r ".action" < $GITHUB_EVENT_PATH)
            if [ "$PR_ACTION" != "opened" ] && [ "$PR_ACTION" != "edited" ] && [ "$PR_ACTION" != "synchronize" ]; then
                echo -e "PR event ($PR_ACTION) contains no changes and does not warrant a Pulumi Preview"
                echo -e "Skipping Pulumi action altogether..."
                exit 0
            fi

            BRANCH=$(jq -r ".pull_request.base.ref" < $GITHUB_EVENT_PATH)
        else
            BRANCH="$GITHUB_REF"
        fi
        BRANCH=$(echo $BRANCH | sed "s/refs\/heads\///g")
    fi

    # Respect the branch mappings file for stack selection. Note that this is *not* required, but if the file
    # is missing, the caller of this script will need to pass `-s <stack-name>` to specify the stack explicitly.
    if [ ! -z "$BRANCH" ]; then
        
        if [ -e $ROOT/.pulumi/ci.json ]; then
            PULUMI_STACK_NAME=$(cat $ROOT/.pulumi/ci.json | jq -r ".\"$BRANCH\"")
        else
            # If there's no stack mapping file, we are on master, and there's a single stack, use it.
            PULUMI_STACK_NAME=$(pulumi stack ls | awk 'FNR == 2 {print $1}' | sed 's/\*//g')
        fi

        if [ ! -z "$PULUMI_STACK_NAME" ] && [ "$PULUMI_STACK_NAME" != "null" ]; then
            pulumi stack select $PULUMI_STACK_NAME
        else
            echo -e "No stack configured for branch '$BRANCH'"
            echo -e ""
            echo -e "To configure this branch, please"
            echo -e "\t1) Run 'pulumi stack init <stack-name>'"
            echo -e "\t2) Associated the stack with the branch by adding"
            echo -e "\t\t{"
            echo -e "\t\t\t\"$BRANCH\": \"<stack-name>\""
            echo -e "\t\t}"
            echo -e "\tto your .pulumi/ci.json file"
            echo -e ""
            echo -e "For now, exiting cleanly without doing anything..."
            exit 0
        fi
    fi
fi

# Next, lazily install packages if required.
if [ -e package.json ] && [ ! -d node_modules ]; then
    npm install
fi

# Now just pass along all arguments to the Pulumi CLI, sending the output to a file for
# later use. Note that we exit immediately on failure (under set -e), so we `tee` stdout, but
# allow errors to be surfaced in the Actions log.
PULUMI_COMMAND="pulumi $*"
PULUMI_SET_REGION="pulumi config set aws:region ${AWS_REGION:-us-east-1}"
OUTPUT_FILE=$(mktemp)
echo "\`$PULUMI_COMMAND\`"
echo "\`$PULUMI_SET_REGION\`"
echo "\`$GITHUB_WORKSPACE/${PULUMI_ROOT:-public}\`"
bash -c "$PULUMI_SET_REGION"
bash -c "$PULUMI_COMMAND" | tee $OUTPUT_FILE
EXIT_CODE=${PIPESTATUS[0]}

# Detect what action is being taken. If it's a PR that's been edited, we will preview the changes;
# if it's a "close" or branch deletion, we will delete the stack; otherwise, we exit cleanly because
# there's nothing to do.

case "$GITHUB_EVENT_NAME" in
    "pull_request")
        # Extract PR attributes.
        GH_PR_ACTION=$(cat "$GITHUB_EVENT_PATH" | jq -r ".action")
        GH_PR_NUMBER=$(cat "$GITHUB_EVENT_PATH" | jq -r ".number")
        COMMENTS_URL=$(cat $GITHUB_EVENT_PATH | jq -r .pull_request.comments_url)
        GH_BRANCH=$(cat "$GITHUB_EVENT_PATH" | jq -r ".pull_request.head.ref")
        echo "# PR #$GH_PR_NUMBER, action '$GH_PR_ACTION', branch $GH_BRANCH"
        COMMENT="#### :tropical_drink: \`$PULUMI_COMMAND\`
\`\`\`
$(cat $OUTPUT_FILE)
\`\`\`"
        PAYLOAD=$(echo '{}' | jq --arg body "$COMMENT" '.body = $body')
        echo "Commenting on PR $COMMENTS_URL"
        curl -s -S -H "Authorization: token $GITHUB_TOKEN" -H "Content-Type: application/json" --data "$PAYLOAD" "$COMMENTS_URL"
        ;;
    "delete")
        # Extract deletion attributes.
        GH_BRANCH=$(cat "$GITHUB_EVENT_PATH" | jq -r ".ref")
        # For branch deletions, always delete the branch.
        PULUMI_UPDATE=false
        ;;
    "push")
        # Extract deletion attributes.
        GH_BRANCH=$(cat "$GITHUB_EVENT_PATH" | jq -r ".ref")
        # For branch deletions, always delete the branch.
        PULUMI_UPDATE=false
        ;;
esac

exit $EXIT_CODE