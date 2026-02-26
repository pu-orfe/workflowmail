# WorkflowMail - Containerized Azure Function for ACS Email
# Use this to build and test the function locally before deploying.
#
# Build:  docker build -t workflowmail .
# Run:    docker run -p 7071:80 \
#           -e ACS_ENDPOINT=https://your-acs.communication.azure.com \
#           -e SENDER_ADDRESS=DoNotReply@xxx.azurecomm.net \
#           workflowmail

FROM mcr.microsoft.com/azure-functions/python:4-python3.11

ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true

COPY function/requirements.txt /home/site/wwwroot/requirements.txt
RUN pip install --no-cache-dir -r /home/site/wwwroot/requirements.txt

COPY function/ /home/site/wwwroot/
