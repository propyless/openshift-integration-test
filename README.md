Openshift Integration Testing
=============================

Integration tests for Openshift is written in Bash and uses the existing functionality in the openshift command line tools (oc).

Below is a example on how to run the integration test with a dotnet s2i image and the source code that should be used. Context dir and also the name to be used for the new app.
./integ-test.sh -H https://web.ocp.local:8443 -c $HOME/.kube/integ_config -a "dotnet~https://github.com/redhat-developer/s2i-dotnetcore-ex.git#dotnetcore-1.1" --context_dir app --app_name integ-test -L .

*Cavecats*:
If a template is used, it should be made sure that the name of the build and service be set to $APPLICATION_NAME.


### Help Output
``Usage example: integ-test.sh
  -h | --hostname             - Hostname of the Openshift Cluster to connect to.
  -c | --auth_kubecfg         - Location of the .kubeconfig file. If you specify.
                                this you do not need to have token if the .kubeconfig.
                                already has a valid login.
  -L | --log_path             - Directory where log files should be placed.
  -l | --auth_token           - Authentication token to use when logging in to OCP cluster.
  -n | --project_name_prefix  - Specify if you want to change prefix of project name (default: integ-test).
  -a | --template             - Name of template you want to run.
  --context_dir               - Context dir used for new app source dir.
  --app_name                  - Name of the application created.
  -r | --route_timeout        - Amount of time to pass before giving up route responding. Default: 120)
  -p | --route_port           - Port to connect when checking route. (Optional)

DNS Checks
  -d | --check_dns            - Enable DNS Checking.
  -i | --dns_ip               - IP Address of the DNS Server.
  -R | --dns_timeout          - Amount of time to pass before giving up checking hostname resolution (Default: 120).
```
