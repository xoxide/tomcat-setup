##############################################################################
# Site management script
#
# This script contains functions for site management, and will run the
# appropriate function based on the arguments passed to it. Most of the
# functionality here is for setting up nginx and tomcat to host sites, as well
# as enabling https for sites.
##############################################################################

list_sites() {
	ssh $user@$ip 'ls -1 /etc/nginx/sites-available' | grep -v '^default$'
}

enable_git_deploment() {
	domain=$1
	echo "Setting up git deployment..."

	ssh -t $user@$ip "
	mkdir /srv/${domain}
	cat > /srv/${domain}/config <<'.'
$(cat $TEMPLATES/config)
.
	git init --bare --shared=group /srv/${domain}/repo.git
	cat > /srv/${domain}/repo.git/hooks/post-receive <<'.'
$(sed -e s/{{site}}/$domain/g $TEMPLATES/post-receive.sh)
.
	chmod +x /srv/${domain}/repo.git/hooks/post-receive
	"
	echo "git deployment configured!"
	echo "Here is your deployment remote:"
	echo
	echo "	$user@$ip:/srv/${domain}/repo.git"
	echo
	echo "You can run something like:"
	echo
	echo "	git remote add production $user@$ip:/srv/${domain}/repo.git"
	echo
	echo "To add the remote."
}

create_site() {
	while getopts 'd:' opt ; do
		case $opt in
			d) domain=${OPTARG};;
		esac
	done
	if [[ -z $domain ]] ; then
		echo 'Setup up the server to host a new site'
		echo
		die '-d <domain>'
	fi

	if list_sites | grep "^$domain$" > /dev/null ; then
		echo 'It looks like that site is already setup. Doing nothing.'
		echo 'If you wish to re-create the site, first remove the site, then'
		echo 're-create it.'
		exit 1
	fi

	# verify dns records
	if [[ "$(dig +short ${domain} | tail -n 1)" != $ip ]]; then
		echo 'It looks like the dns records for that domain are not setup to'
		echo 'point to your server.'
		read -p 'Continue anyway? [y/N] ' confirm
		echo $confirm | grep -i '^y' >/dev/null || exit 1
	fi

	echo "Setting up ${domain}..."

	ssh -t $user@$ip "
	set -e
	# tomcat config
	echo 'Configuring tomcat...'
	sudo perl -i -pe 's!^.*--## Virtual Hosts ##--.*\$!$&\n\
	<Host name=\"${domain}\" appBase=\"${domain}\" unpackWARs=\"true\" autoDeploy=\"true\" />!' \
		/opt/tomcat/conf/server.xml
	sudo mkdir -p /opt/tomcat/${domain}
	sudo chown -R tomcat:tomcat /opt/tomcat/${domain}
	sudo chmod -R g+w /opt/tomcat/${domain}
	echo 'Restarting tomcat...'
	sudo systemctl restart tomcat

	sudo mkdir -p /var/www/${domain}/uploads
	sudo chmod g+rw /var/www/${domain}/uploads
	sudo chown -R tomcat:tomcat /var/www/${domain}/uploads

	# nginx config
	echo 'Configuring nginx...'
	echo '$(sed -e s/{{domain}}/${domain}/g -e s/{{user}}/${user}/g $TEMPLATES/site.nginx.conf)' |\
		sudo tee /etc/nginx/sites-available/${domain} >/dev/null
	sudo ln -s /etc/nginx/sites-available/${domain} /etc/nginx/sites-enabled/${domain}
	echo 'Restarting nginx...'
	sudo systemctl restart nginx
	"
	[[ $? -eq 0 ]] && echo "${domain} created!"

	enable_git_deploment $domain
}

enable_ssl() {
	while getopts 'd:' opt ; do
		case $opt in
			d) domain=${OPTARG};;
		esac
	done
	if [[ -z $domain ]] ; then
		echo 'Enable https for a site'
		echo
		die '-d <domain>'
	fi


	echo 'Before running this command, make sure that the DNS records for your domain'
	echo 'are configured to point to your server.'
	echo 'If they are not properly configured, this command *will* fail.'
	echo
	read -p 'Press Enter to continue, or Ctrl-C to exit'

	ssh -t $user@$ip "
	set -e
	mkdir -p /srv/${domain}
	sudo letsencrypt certonly\
		--authenticator webroot\
		--webroot-path=/var/www/${domain}\
		--domain ${domain}\
		--agree-tos\
		--email $email\
		--renew-by-default >> /srv/letsencrypt.log

	echo 'Setting up nginx to serve ${domain} over https...'
	echo '$(sed -e s/{{domain}}/${domain}/g -e s/{{user}}/${user}/g $TEMPLATES/ssl-site.nginx.conf)' |\
		sudo tee /etc/nginx/sites-available/${domain} >/dev/null
	sudo systemctl restart nginx
	"

	[[ $? -eq 0 ]] && echo "https enabled for ${domain}!"
}

remove_site() {
	while getopts 'd:' opt ; do
		case $opt in
			d) domain=${OPTARG};;
		esac
	done
	if [[ -z $domain ]] ; then
		echo 'Remove a site from the server'
		echo
		die '-d <domain>'
	fi

	# confirm deletion
	read -p "Are your sure you want to remove $site? [y/N] " confirm
	echo "$confirm" | grep -i '^y' >/dev/null
	if [[ $? -ne 0 ]]; then
		echo 'site not removed!'
		exit 1
	fi

	ssh -t $user@$ip "
	ls /etc/nginx/sites-available | grep '^$site$' >/dev/null 2>&1
	if [[ \$? -ne 0 ]]; then
		echo 'That site does not exist!'
		exit 1
	fi

	sudo sed -i -e '/${site}/d' /opt/tomcat/conf/server.xml

	sudo rm -f /etc/nginx/sites-available/${site}
	sudo rm -f /etc/nginx/sites-enabled/${site}
	sudo rm -rf /opt/tomcat/${site}
	sudo rm -rf /opt/tomcat/conf/Catalina/${site}
	sudo rm -rf /var/www/${site}
	sudo rm -rf /srv/${site}
	"

	[[ $? -eq 0 ]] && echo 'site removed!'
}

build_site() {
	while getopts 'd:' opt ; do
		case $opt in
			d) domain=${OPTARG};;
		esac
	done
	if [[ -z $domain ]] ; then
		echo 'Trigger a build and deploy for a site'
		echo
		die '-d <domain>'
	fi

	# ensure site exists
	list_sites | grep "^$site$" >/dev/null 2>&1
	if [[ $? -ne 0 ]]; then
		echo 'That site does not exist!'
		exit 1
	fi

	echo "Running post-receive hook for $site"
	ssh -t $user@$ip "
	cd /srv/$site/repo.git
	hooks/post-receive
	"

}

deploy_site() {
	while getopts 'f:d:' opt ; do
		case $opt in
			f) war_filepath=${OPTARG};;
			d) domain=${OPTARG};;
		esac
	done

	if [[ -z $domain ]] || [[ -z $war_filepath ]] ; then
		echo 'Deploy a pre-built war file.'
		echo
		echo '-d <domain>'
		die '-f <path to the war file>'
	fi

	# ensure file exists and is a war (or at least has the extension)
	if [[ ! -f $war_filepath ]]; then
		echo 'It looks like that file does not exist!'
		exit 1
	fi
	echo $war_filepath | grep '\.war$' >/dev/null
	if [[ $? -ne 0 ]]; then
		echo 'must be a valid .war file'
		exit 1
	fi

	# ensure site exists
	list_sites | grep "^$domain$" >/dev/null 2>&1
	if [[ $? -ne 0 ]]; then
		echo 'That site does not exist!'
		exit 1
	fi

	scp $war_filepath $user@$ip:/opt/tomcat/${domain}/ROOT.war
}

show_info() {
	while getopts 'd:' opt ; do
		case $opt in
			d) domain=${OPTARG};;
		esac
	done
	if [[ -z $domain ]] ; then
		echo 'Show information about a site that is setup on the server'
		echo
		die '-d <domain>'
	fi

	# ensure site exists
	list_sites | grep "^$site$" >/dev/null 2>&1
	if [[ $? -ne 0 ]]; then
		echo 'That site does not exist!'
		exit 1
	fi

	cat <<-.
		Site: $site

		uploads directory:     /var/www/$site/uploads
		nginx config file:     /etc/nginx/sites-available/$site
		deployment git remote: $user@$ip:/srv/$site/repo.git

		To add the deployment remote (from your project, not from $BASE_DIR):

		    git remote add production $user@$ip:/srv/$site/repo.git

	.
}

show_help() {
	cat <<-help
	site -- command for managing sites setup on your server
	usage

	    ./server site <command>

	where <command> is one of the following:

	    list -- list the sites setup on your server

	    create    -d <domain>
	    remove    -d <domain>
	    build     -d <domain>
	    enablessl -d <domain>
	    info      -d <domain>
	    deploy    -d <domain> -f <warfile>

	help
}

command=$1
shift

case $command in
	list|ls)   list_sites;;
	create)	   create_site $@;;
	remove|rm) remove_site $@;;
	build)	   build_site $@;;
	enablessl) enable_ssl $@;;
	info)      show_info $@;;
	deploy)	   deploy_site $@;;
	*)         show_help;;
esac
