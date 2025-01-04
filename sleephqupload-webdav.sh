#!/bin/bash

client_id=""
client_secret=""
base_url="https://sleephq.com"
token_url="$base_url/oauth/token"
api_url="$base_url/api/v1"
my_creds=""
webdavname=""
destinationdir=""
yesterday=$(date -d "yesterday" '+%Y%m%d')
zipname="$yesterday.zip"
time_now=$(date +%s)

# Function to check and create a zip file
check_and_create_zip() {
    echo "Checking and creating zip..."
    
    if [[ ! -d "$destinationdir" ]]; then
        echo "Error: Directory $destinationdir does not exist."
        return 1
    fi
    
	cd "$destinationdir" || { echo "Error: Failed to enter directory $destinationdir"; return 1; }
    
	mkdir -p "zips" 

    # Check if the zip file does not exist or if there is new data to transfer
    if [[ ! -f "zips/$zipname" ]] || ! rclone -v copy "$webdavname" "$destinationdir" 2>&1 | grep -q "There was nothing to transfer"; then
        echo "No yesterday zip or rclone has new data"
									   
        if [[ -z "$(find zips -maxdepth 1 -type f -name "*.zip" | head -n 1)" && -n "$(find DATALOG -type f | head -n 1)" ]]; then 
            echo "Creating full zip"
            zip -r "zips/$zipname" *.* SETTINGS DATALOG || { echo "Error: Failed to create full zip"; return 1; }
        elif [[ -d "DATALOG/$yesterday" ]]; then 
            echo "Creating yesterday zip"
            zip -r "zips/$zipname" *.* SETTINGS "DATALOG/$yesterday" || { echo "Error: Failed to create yesterday zip"; return 1; }
        else 
            echo "No new data to zip; skipping zip creation."
            return 1 
        fi
        echo "Zip created successfully."
        return 0 
    fi
    echo "No changes detected; no zip created."
    return 1
}

# Function to get an access token								 
get_access_token() {
	if [[ -s $my_creds ]]; then
		. "$my_creds"
		if [[ $time_now -lt $expires_at ]]; then
		    echo "Valid access token" 
							  
	        return 0
	   fi
	fi

	auth_result=$(curl -s -X POST "$token_url" \
		-H "Content-Type: application/x-www-form-urlencoded" \
		-d "grant_type=password" \
		-d "client_id=$client_id" \
		-d "client_secret=$client_secret" \
		-d scope='read write delete')
	
	access_token=$(jq -r '.access_token' <<< "$auth_result")
	expires_at=$((time_now + $(jq -r '.expires_in' <<< "$auth_result") - 60))
											  
	if [[ -z "$access_token" || -z "$expires_at" ]]; then
        echo "Error: Failed to retrieve access token or expiration time."
        return 1
    fi

	echo -e "access_token=$access_token\nexpires_at=$expires_at" > "$my_creds"
	echo "New access token $access_token expires at $expires_at"
	return 0
}
										 
upload_and_process() { 
	get_access_token
	if [[ $? -ne 0 ]]; then
        echo "Error: Failed to get access token. Aborting."
        return 1
    fi
	
    # Make sure the access token is set

    if [[ -z "$access_token" ]]; then
        echo "Error: No access token available. Aborting."
        return 1
    fi
	
	teamsid=$(curl -s -X GET "$api_url/me" \
		-H "accept: application/vnd.api+json" \
		-H "authorization: Bearer $access_token" | jq -r '.data.current_team_id') 

    if [[ -z "$teamsid" ]]; then
        echo "Error: Failed to retrieve team ID."
        return 1
    fi
	echo "Teams ID is $teamsid"
	
	importid=$(curl -s -X POST "$api_url/teams/$teamsid/imports" \
		-H "accept: application/vnd.api+json" \
		-H "authorization: Bearer $access_token" \
		-d '' | jq -r '.data.attributes.id')
    
    if [[ -z "$importid" ]]; then
        echo "Error: Failed to retrieve import ID."
        return 1
    fi
    echo "Import ID is $importid"

    contenthash=$(md5sum "$destinationdir/zips/$zipname" | awk '{print $1}')

	upload_response=$(curl -s -X POST "$api_url/imports/$importid/files" \
		-H "accept: application/vnd.api+json" \
		-H "authorization: Bearer $access_token" \
		-H "Content-Type: multipart/form-data" \
		-F "name=$zipname" \
		-F "path=$destinationdir/zips/$zipname" \
		-F "file=@$destinationdir/zips/$zipname;type=application/x-zip-compressed" \
		-F "content_hash=$contenthash")
		
    if [[ $? -ne 0 || -z "$upload_response" ]]; then
        echo "Error: Failed to upload the zip file."
        return 1
    fi

	process_response=$(curl -s -X POST "$api_url/imports/$importid/process_files" \
		-H "accept: application/vnd.api+json" \
		-H "authorization: Bearer $access_token" \
		-d '')

    if [[ $? -ne 0 || -z "$process_response" ]]; then
        echo "Error: Failed to process the files."
        return 1
    fi

	echo "Finished uploading and processing data from $zipname."
	return 0
}

echo "Running script"
check_and_create_zip && upload_and_process
echo "Script ended"
