#!/bin/bash
# © Copyright IBM Corporation 2015.
#
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Eclipse Public License v1.0
# which accompanies this distribution, and is available at
# http://www.eclipse.org/legal/epl-v10.html

# show the commands before execution on stdout and exit on error
set -ex

stop()
{
  echo "----------------------------------------"
  echo "Stopping node MYNODE..."
  mqsistop MYNODE
  echo "----------------------------------------"
  echo "Stopping QM - QM1"
  endmqm QM1
}

start()
{
  echo "----------------------------------------"
  /opt/ibm/iib-${IIB_VERSION}/iib version
  echo "----------------------------------------"
  echo "----------------------------------------"
  echo "Starting syslog"
  sudo /usr/sbin/rsyslogd
  if [ -z "$MQSI_VERSION" ]; then
    echo "Sourcing profile"
    source /opt/ibm/iib-${IIB_VERSION}/server/bin/mqsiprofile
  fi
  if [[ "$IIB_GLOBALCACHE" = @(internal|external) ]]; then
    echo "enable embedded global cache"
    mqsichangebroker MYNODE -b default
  fi

	if [[ -f /secret/pw.sh ]]; then
    echo "Using mounted Kubernetes secret..."
    . /secret/pw.sh
  fi
	#config keystore and keystore pw
	if [[ ! -z "$IIB_KEYSTOREPW" ]] || [[ ! -z "$IIB_TRUSTSTOREPW" ]]; then
		mqsisetdbparms MYNODE -n brokerKeystore::password -u ignore -p $IIB_KEYSTOREPW
		mqsisetdbparms MYNODE -n brokerTruststore::password -u ignore -p $IIB_TRUSTSTOREPW
	fi

  echo "Starting node MYNODE"
  # start QM
  strmqm QM1
  mqsistart MYNODE
  echo "----------------------------------------"
}

config()
{
  echo "----------------------------------------"
  if [[ -f /secret/pw.sh ]]; then
    echo "Using mounted Kubernetes secret..."
    . /secret/pw.sh
  else
    echo "WARNING: Using password environment variables, this is insecure"
    IIB_ADMINPW="${IIB_ADMINPW:-admin}"
    IIB_OBSERVERPW="${IIB_OBSERVERPW:-observer}"
  fi

	echo "Create users with role admin and observer"
	mqsiwebuseradmin MYNODE -c -u admin -a $IIB_ADMINPW -r iibAdmins
	mqsiwebuseradmin MYNODE -c -u observer -a $IIB_OBSERVERPW -r iibObserver

	echo "Applying the iib admin inteface config"
  mqsichangefileauth MYNODE -r iibObserver -p read+
  mqsichangefileauth MYNODE -r iibAdmins -p all+

	echo "give user permission on the integration server"
	mqsichangefileauth MYNODE -r iibObserver -p read+ -e default
	mqsichangefileauth MYNODE -r iibAdmins -p all+ -e default

  echo "Check file auth"
  mqsireportfileauth MYNODE -l

	echo "Check the HTTPS Connector"
	mqsireportproperties MYNODE -e default -o HTTPSConnector  -r

	IIB_TRACEMODE="${IIB_TRACEMODE:-off}"
  echo "Set trace nodes to:" $IIB_TRACEMODE
  /opt/ibm/iib-${IIB_VERSION}/server/bin/mqsichangetrace MYNODE -n $IIB_TRACEMODE -e default

  # configure a external global cache
  if [ "$IIB_GLOBALCACHE" = external ]; then
    echo "configure external globale cache from an IBM Extreme Scale"
    mqsisetdbparms MYNODE  -n wxs::id1 -u $IIB_GC_USER -p $IIB_GC_PASSWD
    mqsicreateconfigurableservice MYNODE -c WXSServer -o xc10 -n catalogServiceEndPoints,gridName,securityIdentity -v \"$IIB_GC_CATALOGENDPOINT\",$IIB_GC_GRIDNAME,id1
    mqsichangeproperties MYNODE -o ComIbmJVMManager -e default -n jvmMaxHeapSize -v 1536870912
    echo "restart IBM Integration Bus"
    server/bin/mqsistop MYNODE
    server/bin/mqsistart MYNODE
  fi

	# add keystore config
	if [[ -f /secret/keystore.jks ]] && [[ -f /secret/truststore.jks ]]; then
		echo "configure keystore and truststore if exists"
		mqsichangeproperties MYNODE -o BrokerRegistry -n brokerKeystoreFile -v /secret/keystore.jks
		mqsichangeproperties MYNODE -o BrokerRegistry -n brokerTruststoreFile -v /secret/truststore.jks
	fi


  if [ -x /usr/local/bin/customconfig.sh ]; then
    /usr/local/bin/customconfig.sh
  fi

	# create file to indicate that container is allready configure this is used
	# after restart to skip config if this file exists
	touch /iib-configured

}

deploy()
{
  echo "----------------------------------------"
  echo "Running - deploying application from /iibProjects"
  # do it with an add wget -O /iibProjects/app.bar http://config-host/app.bar && rm app.bar
  echo "importing applications in /iibProjects/*"
  FILES=/iibProjects/*
  for f in $FILES; do
    filename=$(basename "$f")
    filenamewithoutextension=$(basename "$f" | cut -d. -f1)
    #ls -ll /iibProperties/
    if [ ! -f /iibDeployed/$filename ]; then
      if [ -f /iibProperties/$filenamewithoutextension.properties ]; then
        echo "... configure $f  with properties file ..."
        mqsiapplybaroverride -b $f -p ./iibProperties/$filenamewithoutextension.properties -r
      fi
      echo "... importing $f ..."
      mqsideploy MYNODE -e default -a $f -m -w 120
      echo " ... done!"
    else
      echo "... NOT importing $f because it has already been deployed to this container"
      echo "... set REDEPLOY-Environment-Variable to true if you want to redeploy"
    fi
  done
}

iib-license-check.sh
start

# configure iib if not allready done
if [[ ! -f /iib-configured ]]; then
	config
fi

if [[ "${IIB_SKIPDEPLOY}" != 'true' ]]; then
    deploy
fi

trap stop SIGTERM SIGINT
tail -f /var/log/syslog
