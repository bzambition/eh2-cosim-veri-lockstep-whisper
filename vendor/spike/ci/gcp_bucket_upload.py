#!/usr/bin/python3

# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

from google.cloud import storage
import sys
import os
import os.path
import json

def upload_to_bucket(bucket_name, filename):
    json_auth_info = json.loads(os.environ['GCP_AUTH_JSON'])
    storage_client = storage.Client.from_service_account_info(json_auth_info)

    bucket = storage_client.bucket(bucket_name)

    object_name = os.path.basename(filename)
    blob = bucket.blob(object_name)

    if blob.exists():
        print("File already exists, skipping upload")
    else:
        blob.upload_from_filename(filename)

    return blob.public_url

if __name__ == "__main__":
    print(upload_to_bucket(sys.argv[1], sys.argv[2]))
