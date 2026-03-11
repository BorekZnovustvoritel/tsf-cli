#!/bin/bash
#
# Test script for TPA release client
# This creates a test job to verify the release client can upload SBOMs
#

set -e

NAMESPACE="${NAMESPACE:-tsf-tpa}"
KEYCLOAK_URL="${KEYCLOAK_URL:-https://sso.apps.cluster-52zmf.52zmf.sandbox1388.opentlc.com/realms/tsf-iam}"
TPA_URL="${TPA_URL:-https://server-tsf-tpa.apps.cluster-52zmf.52zmf.sandbox1388.opentlc.com}"

echo "=== Creating Test Resources for TPA Release Client ==="
echo ""
echo "Configuration:"
echo "  Namespace: ${NAMESPACE}"
echo "  Keycloak URL: ${KEYCLOAK_URL}"
echo "  TPA URL: ${TPA_URL}"
echo ""

# Create the test resources
kubectl apply -f - <<EOF
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: test-sbom
  namespace: ${NAMESPACE}
data:
  sample.json: |
    {
      "bomFormat": "CycloneDX",
      "specVersion": "1.4",
      "serialNumber": "urn:uuid:3e671687-395b-41f5-a30f-a58921a69b79",
      "version": 1,
      "metadata": {
        "timestamp": "2024-03-11T10:00:00Z",
        "component": {
          "type": "application",
          "bom-ref": "test-app",
          "name": "test-application",
          "version": "1.0.0"
        }
      },
      "components": [
        {
          "type": "library",
          "bom-ref": "pkg:maven/org.example/test-lib@1.0.0",
          "name": "test-lib",
          "version": "1.0.0",
          "purl": "pkg:maven/org.example/test-lib@1.0.0"
        }
      ]
    }
---
apiVersion: batch/v1
kind: Job
metadata:
  name: test-release-client
  namespace: ${NAMESPACE}
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: test-release-client
    spec:
      restartPolicy: Never
      containers:
      - name: test-upload
        image: quay.io/curl/curl:latest
        command:
        - /bin/sh
        - -c
        - |
          set -e
          
          echo "=== Testing TPA Release Client ==="
          echo ""
          
          # Download jq
          echo "Downloading jq..."
          wget -q -O /tmp/jq https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64
          chmod +x /tmp/jq
          echo ""
          
          # Read credentials from secret
          CLIENT_ID="release"
          CLIENT_SECRET=\$(cat /var/run/secrets/oidc/release)
          KEYCLOAK_URL="${KEYCLOAK_URL}"
          TPA_URL="${TPA_URL}"
          
          echo "Configuration:"
          echo "  Client ID: \${CLIENT_ID}"
          echo "  Keycloak URL: \${KEYCLOAK_URL}"
          echo "  TPA URL: \${TPA_URL}"
          echo ""
          
          # Get OIDC token
          echo "Step 1: Obtaining OIDC token..."
          TOKEN_RESPONSE=\$(curl -s -X POST "\${KEYCLOAK_URL}/protocol/openid-connect/token" \\
            -H "Content-Type: application/x-www-form-urlencoded" \\
            -d "grant_type=client_credentials" \\
            -d "client_id=\${CLIENT_ID}" \\
            -d "client_secret=\${CLIENT_SECRET}")
          
          ACCESS_TOKEN=\$(echo "\${TOKEN_RESPONSE}" | /tmp/jq -r '.access_token')
          
          if [ "\${ACCESS_TOKEN}" = "null" ] || [ -z "\${ACCESS_TOKEN}" ]; then
            echo "ERROR: Failed to obtain access token"
            echo "Response: \${TOKEN_RESPONSE}"
            exit 1
          fi
          
          echo "✓ Successfully obtained access token"
          echo "  Token (first 50 chars): \${ACCESS_TOKEN:0:50}..."
          echo ""
          
          # Verify token contains expected scopes
          echo "Step 2: Verifying token scopes..."
          TOKEN_PAYLOAD=\$(echo "\${ACCESS_TOKEN}" | cut -d. -f2 | base64 -d 2>/dev/null || echo "{}")
          echo "  Token payload: \${TOKEN_PAYLOAD}" | /tmp/jq . || true
          echo ""
          
          # Upload SBOM
          echo "Step 3: Uploading sample SBOM to TPA..."
          UPLOAD_RESPONSE=\$(curl -s -w "\\nHTTP_CODE:%{http_code}" -X POST "\${TPA_URL}/api/v2/sbom" \\
            -H "Authorization: Bearer \${ACCESS_TOKEN}" \\
            -H "Content-Type: application/json" \\
            --data-binary @/var/run/sbom/sample.json)
          
          HTTP_CODE=\$(echo "\${UPLOAD_RESPONSE}" | grep "HTTP_CODE:" | cut -d: -f2)
          RESPONSE_BODY=\$(echo "\${UPLOAD_RESPONSE}" | sed '/HTTP_CODE:/d')
          
          echo "  HTTP Status Code: \${HTTP_CODE}"
          echo "  Response: \${RESPONSE_BODY}"
          echo ""
          
          # Check result
          if [ "\${HTTP_CODE}" = "201" ] || [ "\${HTTP_CODE}" = "200" ]; then
            echo "✓✓✓ SUCCESS! ✓✓✓"
            echo "The release client successfully uploaded an SBOM to TPA!"
            echo ""
            echo "Summary:"
            echo "  - OIDC token obtained: ✓"
            echo "  - SBOM uploaded: ✓"
            echo "  - HTTP Status: \${HTTP_CODE}"
            exit 0
          else
            echo "✗✗✗ FAILED! ✗✗✗"
            echo "SBOM upload failed with HTTP status \${HTTP_CODE}"
            echo ""
            echo "This could mean:"
            echo "  - The release client lacks required permissions"
            echo "  - TPA authentication is not properly configured"
            echo "  - The SBOM format is invalid"
            exit 1
          fi
        env:
        - name: KEYCLOAK_URL
          value: "${KEYCLOAK_URL}"
        - name: TPA_URL
          value: "${TPA_URL}"
        volumeMounts:
        - name: oidc-secret
          mountPath: /var/run/secrets/oidc
          readOnly: true
        - name: sbom-data
          mountPath: /var/run/sbom
          readOnly: true
      volumes:
      - name: oidc-secret
        secret:
          secretName: tpa-realm-clients
          items:
          - key: release
            path: release
      - name: sbom-data
        configMap:
          name: test-sbom
EOF

echo ""
echo "✓ Test job created successfully!"
echo ""
echo "To monitor the test:"
echo "  kubectl logs -n ${NAMESPACE} -f job/test-release-client"
echo ""
echo "To check results:"
echo "  kubectl get job -n ${NAMESPACE} test-release-client"
echo "  kubectl logs -n ${NAMESPACE} job/test-release-client"
echo ""
echo "To clean up after testing:"
echo "  kubectl delete job -n ${NAMESPACE} test-release-client"
echo "  kubectl delete configmap -n ${NAMESPACE} test-sbom"
echo ""
