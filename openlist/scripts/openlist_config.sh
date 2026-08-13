#!/bin/sh

source /koolshare/scripts/base.sh
eval $(dbus export openlist_)
alias echo_date='echo 【$(TZ=UTC-8 date -R +%Y年%m月%d日\ %X)】:'
OpenListBaseDir=/koolshare/configs/openlist
LOG_FILE=/tmp/upload/openlist_log.txt
LOCK_FILE=/var/lock/openlist.lock
OPENLIST_RUN_LOG=/tmp/upload/openlist_run_log.txt
configRunPath=${OpenListBaseDir}'/' # 运行时db等文件存放目录 默认放到/koolshare/目录下
BASH=${0##*/}
ARGS=$@
# 初始化配置变量
configPort=5244
configHttpsPort=5245
configTokenExpiresIn=48
cofigMaxConnections=0
configSiteUrl=
configDisableHttp=false
configForceHttps=false
configHttps=false
configCertFile=''
configKeyFile=''
configDelayedStart=0
configCheckSslCert=true
ADMIN_USER=
ADMIN_PASS=

set_lock() {
	exec 233>${LOCK_FILE}
	flock -n 233 || {
		# bring back to original log
		http_response "$ACTION"
		exit 1
	}
}

unset_lock() {
	flock -u 233
	rm -rf ${LOCK_FILE}
}

number_test() {
	case $1 in
	'' | *[!0-9]*)
		echo 1
		;;
	*)
		echo 0
		;;
	esac
}

detect_url() {
	local fomart_1=$(echo $1 | grep -E "^https://|^http://")
	local fomart_2=$(echo $1 | grep -E "\.")
	if [ -n "${fomart_1}" -a -n "${fomart_2}" ]; then
		return 0
	else
		return 1
	fi
}

dbus_rm() {
	# remove key when value exist
	if [ -n "$1" ]; then
		dbus remove $1
	fi
}

detect_running_status() {
	local BINNAME=$1
	local PID
	local i=40
	until [ -n "${PID}" ]; do
		usleep 250000
		i=$(($i - 1))
		PID=$(pidof ${BINNAME})
		if [ "$i" -lt 1 ]; then
			echo_date "🔴${1}进程启动失败, 请检查你的配置!"
			dbus set openlist_enable=0
			stop_plugin
			return
		fi
	done
	echo_date "🟢${1}启动成功, pid: ${PID}"
}

check_usb2jffs_used_status() { # 查看当前/jffs的挂载点是什么设备, 如/dev/mtdblock9, /dev/sda1；有usb2jffs的时候, /dev/sda1, 无usb2jffs的时候, /dev/mtdblock9, 出问题未正确挂载的时候, 为空
	local cur_patition=$(df -h | /bin/grep /jffs | awk '{print $1}')
	local jffs_device="not mount"
	if [ -n "${cur_patition}" ]; then
		jffs_device=${cur_patition}
	fi
	local mounted_nu=$(mount | /bin/grep "${jffs_device}" | grep -E "/tmp/mnt/|/jffs" | /bin/grep -c "/dev/s")
	if [ "${mounted_nu}" -eq "2" ]; then
		echo "1" # 已安装并成功挂载
	else
		echo "0" # 未安装或未挂载
	fi
}
# 获取或生成JWT密钥
get_jwt_secret() {
	local jwt_secret=$(dbus get openlist_jwt_secret)
	if [ -z "${jwt_secret}" ]; then
		jwt_secret=$(openssl rand -hex 8)
		dbus set openlist_jwt_secret=${jwt_secret}
	fi
	echo $jwt_secret
}

write_backup_job() {
	sed -i '/openlist_backupdb/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	echo_date "ℹ️[Tmp目录模式] 创建 OpenList 数据库备份任务"
	cru a openlist_backupdb "*/1 * * * * /bin/sh /koolshare/scripts/openlist_config.sh backup"
}

kill_cron_job() {
	if [ -n "$(cru l | grep openlist_backupdb)" ]; then
		echo_date "ℹ️[Tmp目录模式] 删除 OpenList 数据库备份任务..."
		sed -i '/openlist_backupdb/d' /var/spool/cron/crontabs/* >/dev/null 2>&1
	fi
}

restore_openlist_used_db() {
	if [ -f "/tmp/upload/run_openlist/data.db" ]; then
		cp -rf /tmp/upload/run_openlist/data.db* /koolshare/configs/openlist >/dev/null 2>&1
		echo_date "➡️[Tmp目录模式] 复制 OpenList 数据库至备份目录!"
		rm -rf /tmp/upload/run_openlist/
	fi
	kill_cron_job
}

check_run_mode() {
	if [ $(check_usb2jffs_used_status) == "1" ] && [ "${1}" == "start" ]; then
		echo_date "➡️检测到已安装插件usb2jffs并成功挂载, 插件可以正常启动!"
		restore_openlist_used_db
	fi
}

checkDbFilePath() {
	local ACT=${1}
	check_run_mode ${ACT}
	# 检查db运行目录是放在/tmp还是/koolshare
	if [ "${ACT}" = "start" ]; then
		if [ $(check_usb2jffs_used_status) != "1" ]; then # 未挂载usb2jffs就检测是否需要运行在/tmp目录
			local LINUX_VER=$(uname -r | awk -F"." '{print $1$2}')
			if [ "$LINUX_VER" = 41 ]; then # 内核过低就运行在Tmp目录
				echo_date "⚠️检测到内核版本过低, 设置 OpenList 为Tmp目录模式!"
				configRunPath='/tmp/upload/run_openlist/'
				echo_date "⚠️安装usb2jffs插件并成功挂载可恢复正常运行模式!"
				echo_date "⚠️[Tmp目录模式] OpenList 将运行在/tmp目录!"
				mkdir -p /tmp/upload/run_openlist/
				if [ ! -f "/tmp/upload/run_openlist/data.db" ]; then
					cp -rf ${OpenListBaseDir}/data.db* /tmp/upload/run_openlist/ >/dev/null 2>&1
					echo_date "➡️[Tmp目录模式] 复制 OpenList 数据库至使用目录!"
				fi
				write_backup_job
			fi
		fi
	else
		restore_openlist_used_db
	fi
}

makeConfig() {
	echo_date "➡️生成 OpenList 配置文件到${OpenListBaseDir}/config.json!"

	# 初始化端口
	if [ $(number_test ${openlist_port}) != "0" ]; then
		dbus set openlist_port=${configPort}
	else
		configPort=${openlist_port}
	fi

	# 初始化缓存清除时间
	if [ $(number_test ${openlist_token_expires_in}) != "0" ]; then
		dbus set openlist_token_expires_in=${configTokenExpiresIn}
	else
		configTokenExpiresIn=${openlist_token_expires_in}
	fi

	# 初始化最大并发连接数
	if [ $(number_test ${openlist_max_connections}) != "0" ]; then
		dbus set openlist_max_connections=${cofigMaxConnections}
	else
		cofigMaxConnections=${openlist_max_connections}
	fi

	# 初始化https端口
	if [ $(number_test ${openlist_https_port}) != "0" ]; then
		dbus set openlist_https_port=${configHttpsPort}
	else
		configHttpsPort=${openlist_https_port}
	fi

	# 初始化强制跳转https
	if [ $(number_test ${openlist_force_https}) != "0" ]; then
		dbus set openlist_force_https="0"
	fi

	# 初始化强制跳转https
	if [ $(number_test ${openlist_force_https}) != "0" ]; then
		dbus set openlist_force_https="0"
	fi

	# 初始化延迟启动时间
	if [ $(number_test ${openlist_delayed_start}) != "0" ]; then
		dbus set openlist_delayed_start=0
	else
		configDelayedStart=${openlist_delayed_start}
	fi

	# 检查openlist运行DB目录
	checkDbFilePath start

	# 静态资源CDN
	local configCdn=$(dbus get openlist_cdn)
	if [ -n "${configCdn}" ]; then
		detect_url ${configCdn}
		if [ "$?" != "0" ]; then
			# 非url, 清空后使用/
			echo_date "⚠️CDN格式错误!这将导致面板无法访问!"
			echo_date "⚠️本次插件启动不会将此CDN写入配置, 下次请更正, 继续..."
			configCdn=''
			dbus set openlist_cdn_error=1
		else
			# 检测是否为饿了么CDN如果为饿了么CDN则强行替换成本地静态资源
			local MATCH_1=$(echo ${configCdn} | grep -Eo "npm.elemecdn.com")
			if [ -n "${MATCH_1}" ]; then
				echo_date "⚠️检测到你配置了饿了么CDN, 当前饿了么CDN已经失效! 这将导致面板无法访问!"
				echo_date "⚠️本次插件启动不会将此CDN写入配置, 下次请更正, 继续..."
				configCdn=''
				dbus set openlist_cdn_error=1
			fi
		fi
	else
		configCdn=''
	fi

	# 初始化https, 条件:
	# 1. 必须要开启公网访问
	# 2. https开关要打开
	# 3. 证书文件路径和密钥文件路径都不能为空
	# 4. 证书文件和密钥文件要在路由器内找得到
	# 5. 证书文件和密钥文件要是合法的
	# 6. 证书文件和密钥文件还必须得相匹配
	# 7. 继续往下的话就是验证下证书中的域名是否和URL中的域名匹配...算了太麻烦没必要做了
	if [ "${openlist_publicswitch}" == "1" ]; then
		# 1. 必须要开启公网访问
		if [ "${openlist_https}" == "1" ]; then
			# 2. https开关要打开
			if [ -n "${openlist_cert_file}" -a -n "${openlist_key_file}" ]; then
				# 3. 证书文件路径和密钥文件路径都不能为空
				if [ -f "${openlist_cert_file}" -a -f "${openlist_key_file}" ]; then
					# 4. 证书文件和密钥文件要在路由器内找得到
					local CER_VERFY=$(openssl x509 -noout -pubkey -in ${openlist_cert_file} 2>/dev/null)
					local KEY_VERFY=$(openssl pkey -pubout -in ${openlist_key_file} 2>/dev/null)
					if [ -n "${CER_VERFY}" -a -n "${KEY_VERFY}" ]; then
						# 5. 证书文件和密钥文件要是合法的
						local CER_MD5=$(echo "${CER_VERFY}" | md5sum | awk '{print $1}')
						local KEY_MD5=$(echo "${KEY_VERFY}" | md5sum | awk '{print $1}')
						if [ "${CER_MD5}" == "${KEY_MD5}" ]; then
							# 6. 证书文件和密钥文件还必须得相匹配
							echo_date "🆗证书校验通过! 为 OpenList 面板启用https..."
							configHttps=true
							configCertFile=${openlist_cert_file}
							configKeyFile=${openlist_key_file}
						else
							echo_date "⚠️无法启用https, 原因如下:"
							echo_date "⚠️证书公钥: ${openlist_cert_file} 和证书私钥: ${openlist_key_file}不匹配!"
							dbus set openlist_cert_error=1
							dbus set openlist_key_error=1
						fi
					else
						echo_date "⚠️无法启用https, 原因如下:"
						if [ -z "${CER_VERFY}" ]; then
							echo_date "⚠️证书公钥Cert文件错误, 检测到这不是公钥文件!"
							dbus set openlist_cert_error=1
						fi
						if [ -z "${KEY_VERFY}" ]; then
							echo_date "⚠️证书私钥Key文件错误, 检测到这不是私钥文件!"
							dbus set openlist_key_error=1
						fi
					fi
				else
					echo_date "⚠️无法启用https, 原因如下:"
					if [ ! -f "${openlist_cert_file}" ]; then
						echo_date "⚠️未找到证书公钥Cert文件!"
						dbus set openlist_cert_error=1
					fi
					if [ ! -f "${openlist_key_file}" ]; then
						echo_date "⚠️未找到证书私钥Key文件!"
						dbus set openlist_key_error=1
					fi
				fi
			else
				echo_date "⚠️无法启用https, 原因如下:"
				if [ -z "${openlist_cert_file}" ]; then
					echo_date "⚠️证书公钥Cert文件路径未配置!"
					dbus set openlist_cert_error=1
				fi
				if [ -z "${openlist_key_file}" ]; then
					echo_date "⚠️证书私钥Key文件路径未配置!"
					dbus set openlist_key_error=1
				fi
			fi
		fi
	fi

	# 检查关闭http访问
	if [ "${configHttps}" == "true" ]; then
		if [ "${configHttpsPort}" == "${configPort}" ]; then
			configHttps=false
			configHttpsPort="-1"
			echo_date "⚠️ OpenList 管理面板http和https端口相同, 本次启动关闭https!"
		else
			if [ "${openlist_force_https}" == "1" ]; then
				echo_date "🆗 OpenList 管理面板已开启强制跳转https。"
				configForceHttps=true
			fi
		fi
	else
		configHttpsPort="-1"
	fi

	# 网站url只有在开启公网访问后才可用, 且未开https的时候, 网站url不能配置为https; 格式错误的时候, 需要清空, 以免面板入口用了这个URL导致无法访问
	if [ "${openlist_publicswitch}" == "1" ]; then
		if [ -n "${openlist_site_url}" ]; then
			detect_url ${openlist_site_url}
			if [ "$?" != "0" ]; then
				echo_date "⚠️网站URL: ${openlist_site_url} 格式错误!"
				echo_date "⚠️本次插件启动不会将此网站URL写入配置, 下次请更正, 继续..."
				dbus set openlist_url_error=1
			else
				local MATCH_2=$(echo "${openlist_site_url}" | grep -Eo "ddnsto|kooldns|tocmcc")
				local MATCH_3=$(echo "${openlist_site_url}" | grep -Eo "^https://")
				local MATCH_4=$(echo "${openlist_site_url}" | grep -Eo "^http://")
				if [ -n "${MATCH_2}" ]; then
					# ddnsto, 不能开https
					if [ "${configHttps}" == "true" ]; then
						echo_date "⚠️网站URL: ${openlist_site_url} 来自ddnsto!"
						echo_date "⚠️你需要关闭 OpenList 的https, 不然将导致无法访问面板!"
					fi
				else
					# ddns, 根据情况判断
					if [ -n "${MATCH_3}" -a "${configHttps}" != "true" ]; then
						echo_date "⚠️网站URL: ${openlist_site_url} 格式为https!"
						echo_date "⚠️你需要启用 OpenList 的https功能, 不然会导致面 OpenList 部分功能出现问题!"
					elif [ -n "${MATCH_4}" -a "${configHttps}" == "true" ]; then
						echo_date "⚠️网站URL: ${openlist_site_url} 格式为http!"
						echo_date "⚠️你需要启用 OpenList 的https, 或者更改网站URL为http协议, 不然将导致无法访问面板!"
					else
						# 路由器中使用网站URL的话, 还必须配置端口
						if [ -n "${MATCH_3}" ]; then
							local rightPort=$configHttpsPort
							local MATCH_5=$(echo "${openlist_site_url}" | grep -Eo ":${configHttpsPort}$")
						else
							local rightPort=$configHttpsPort
							local MATCH_5=$(echo "${openlist_site_url}" | grep -Eo ":${configPort}$")
						fi
						if [ -z "${MATCH_5}" ]; then
							echo_date "⚠️网站URL: ${openlist_site_url} 端口配置错误!"
							echo_date "⚠️你需要为网站URL配置端口:${rightPort}, 不然会导致面 OpenList 部分功能出现问题!"
						fi
					fi
				fi
				# 只要网址正确就写入配置, 只检测提示, 不阻止写入。2024年11月6日修改
				configSiteUrl=${openlist_site_url}
			fi
		fi
	else
		local dummy
		# 配置了网站URL, 但是没有开启公网访问; 只有打开公网访问后配置网站URL才有意义, 所以插件将不会启用网站URL... 不过也不需要日志告诉用户, 因为插件里关闭公网访问的时候网站URL也被隐藏了的
	fi

	# 公网/内网访问
	local BINDADDR
	local LANADDR=$(ifconfig br0 | grep -Eo "inet addr.+" | awk -F ":| " '{print $3}' 2>/dev/null)
	if [ "${openlist_publicswitch}" != "1" ]; then
		if [ -n "${LANADDR}" ]; then
			BINDADDR=${LANADDR}
		else
			BINDADDR="0.0.0.0"
		fi
	else
		BINDADDR="0.0.0.0"
	fi
	local JWT_SECRET=$(get_jwt_secret)

	# 生成配置文件
	config='{
"force":false,
"jwt_secret":"'${JWT_SECRET}'",
"token_expires_in":'${configTokenExpiresIn}',
"site_url":"'${configSiteUrl}'",
"cdn":"'${configCdn}'",
"database":
	{
		"type":"sqlite3",
		"host":"","port":0,
		"user":"",
		"password":"",
		"name":"",
		"db_file":"'${configRunPath}'data.db",
		"table_prefix":"x_",
		"ssl_mode":""
	},
"scheme":
	{
		"address":"'${BINDADDR}'",
		"http_port":'${configPort}',
		"https_port":'${configHttpsPort}',
		"force_https":'${configForceHttps}',
		"cert_file":"'${configCertFile}'",
		"key_file":"'${configKeyFile}'",
		"unix_file":""
	},
"temp_dir":"'${configRunPath}'temp",
"bleve_dir":"'${configRunPath}'bleve",
"log":
	{
		"enable":true,
		"name":"'${OPENLIST_RUN_LOG}'",
		"max_size":1,
		"max_backups":1,
		"max_age":7,
		"compress":true
	},
"delayed_start": '${configDelayedStart}',
"max_connections":'${cofigMaxConnections}',
"tls_insecure_skip_verify": '${configCheckSslCert}'
}'
	echo "${config}" >${OpenListBaseDir}/config.json
}

# 检查已开启插件
check_enable_plugin() {
	echo_date "ℹ️当前已开启如下插件:"
	echo_date "➡️"$(dbus listall | grep 'enable=1' | awk -F '_' '!a[$1]++' | awk -F '_' '{print "dbus get softcenter_module_"$1"_title"|"sh"}' | tr '\n' ',' | sed 's/,$/ /')
}

make_random_password() {
	/koolshare/bin/openlist --data ${OpenListBaseDir} admin random >${OpenListBaseDir}/admin.account 2>&1
	ADMIN_USER=$(cat ${OpenListBaseDir}/admin.account | grep "username:" | awk '{print $NF}')
	ADMIN_PASS=$(cat ${OpenListBaseDir}/admin.account | grep "password:" | awk '{print $NF}')
}

# 检查内存是否合规
check_memory() {
	local swap_size=$(free | grep Swap | awk '{print $2}')
	echo_date "ℹ️检查系统内存是否合规!"
	if [ "$swap_size" != "0" ]; then
		echo_date "✅️当前系统已经启用虚拟内存! 容量: ${swap_size}KB"
	else
		local memory_size=$(free | grep Mem | awk '{print $2}')
		if [ "$memory_size" != "0" ]; then
			if [ $memory_size -le 750000 ]; then
				echo_date "❌️插件启动异常!"
				echo_date "❌️检测到系统内存为: ${memory_size}KB, 需挂载虚拟内存!"
				echo_date "❌️OpenList程序对路由器开销极大, 请挂载1G及以上虚拟内存后重新启动插件!"
				stop_process
				dbus set openlist_memory_error=1
				dbus set openlist_enable=0
				exit
			else
				echo_date "⚠️OpenList程序对路由器开销极大, 建议挂载1G及以上虚拟内存, 以保证稳定!"
				dbus set openlist_memory_warn=1
			fi
		else
			echo_date "⚠️未查询到系统内存, 请自行注意系统内存!"
		fi
	fi
	echo_date "=============================================="
}

start_process() {
	rm -rf ${OPENLIST_RUN_LOG}
	if [ "${openlist_watchdog}" == "1" ]; then
		echo_date "🟠启动 OpenList 进程, 开启进程实时守护..."
		mkdir -p /koolshare/perp/openlist
		cat >/koolshare/perp/openlist/rc.main <<-EOF
			#!/bin/sh
			source /koolshare/scripts/base.sh
			CMD="/koolshare/bin/openlist --data ${OpenListBaseDir} server"
			if test \${1} = 'start' ; then
				exec >/dev/null 2>&1
				exec \$CMD
			fi
			exit 0

		EOF
		chmod +x /koolshare/perp/openlist/rc.main
		chmod +t /koolshare/perp/openlist/
		sync
		perpctl A openlist >/dev/null 2>&1
		perpctl u openlist >/dev/null 2>&1
		detect_running_status openlist
	else
		echo_date "🟠启动 OpenList 进程..."
		rm -rf /tmp/openlist.pid
		start-stop-daemon --start --quiet --make-pidfile --pidfile /tmp/openlist.pid --background --startas /bin/sh -- -c "exec /koolshare/bin/openlist --data ${OpenListBaseDir} server >/dev/null 2>&1"
		detect_running_status openlist
	fi
}

start() {
	# 0. prepare folder if not exist
	mkdir -p ${OpenListBaseDir}

	# 1. remove error
	dbus_rm openlist_cert_error
	dbus_rm openlist_key_error
	dbus_rm openlist_url_error
	dbus_rm openlist_cdn_error
	dbus_rm openlist_memory_error
	dbus_rm openlist_memory_warn

	# 2. system_check
	if [ "${openlist_disablecheck}" = "1" ]; then
		echo_date "⚠️您已关闭系统检测功能, 请自行留意路由器性能!"
		echo_date "⚠️插件对路由器性能的影响请您自行处理!!!"
	else
		echo_date "==================== 系统检测 ===================="
		# 2.1 memory_check
		check_memory
		# 2.2 enable_plugin
		check_enable_plugin
		echo_date "==================== 系统检测结束 ===================="
	fi

	# 3. stop first
	stop_process

	# 4. gen config.json
	makeConfig

	# 5. set is first run
	if [ ! -f "${OpenListBaseDir}/data.db" ]; then
		echo_date "ℹ️检测到首次启动插件, 生成用户和密码..."
		echo_date "ℹ️初始化操作较耗时, 请耐心等待..."
		make_random_password
		if [ -n "${ADMIN_USER}" -a -n "${ADMIN_PASS}" ]; then
			echo_date "---------------------------------"
			echo_date "😛 OpenList 面板用户: ${ADMIN_USER}"
			echo_date "🔑 OpenList 面板密码: ${ADMIN_PASS}"
			echo_date "---------------------------------"
			dbus set openlist_user=${ADMIN_USER}
			dbus set openlist_pass=${ADMIN_PASS}
		fi
	fi

	# 6. gen version info everytime
	/koolshare/bin/openlist version >${OpenListBaseDir}/openlist.version

	# 7. start process
	start_process

	# 8. open port
	if [ "${openlist_publicswitch}" == "1" ]; then
		close_port >/dev/null 2>&1
		open_port
	fi
}

stop_process() {
	local OPENLIST_PID=$(pidof openlist)
	checkDbFilePath stop
	if [ -n "${OPENLIST_PID}" ]; then
		echo_date "⛔关闭 OpenList 进程..."
		if [ -f "/koolshare/perp/openlist/rc.main" ]; then
			perpctl d openlist >/dev/null 2>&1
		fi
		rm -rf /koolshare/perp/openlist
		killall openlist >/dev/null 2>&1
		kill -9 "${OPENLIST_PID}" >/dev/null 2>&1
		# remove log
		rm -rf "$OPENLIST_RUN_LOG"
	fi
}

stop_plugin() {
	# 1 stop openlist
	stop_process

	# 2. close port
	close_port
}

open_port() {
	local CM=$(lsmod | grep xt_comment)
	local OS=$(uname -r)
	if [ -z "${CM}" -a -f "/lib/modules/${OS}/kernel/net/netfilter/xt_comment.ko" ]; then
		echo_date "ℹ️加载xt_comment.ko内核模块!"
		insmod /lib/modules/${OS}/kernel/net/netfilter/xt_comment.ko
	fi

	if [ $(number_test ${openlist_port}) != "0" ]; then
		dbus set openlist_port="5244"
	fi

	if [ $(number_test ${openlist_https_port}) != "0" ]; then
		dbus set openlist_https_port="5245"
	fi

	# 开启IPV4防火墙端口
	local MATCH=$(iptables -t filter -S INPUT | grep "openlist_rule")
	if [ -z "${MATCH}" ]; then
		if [ "${configDisableHttp}" != "true" -a "${openlist_open_http_port}" == "1" ]; then
			echo_date "🧱添加防火墙入站规则, 打开 OpenList http 端口: ${openlist_port}"
			iptables -I INPUT -p tcp --dport ${openlist_port} -j ACCEPT -m comment --comment "openlist_rule" >/dev/null 2>&1
		fi
		if [ "${openlist_https}" == "1" -a "${openlist_open_https_port}" == "1" ]; then
			echo_date "🧱添加防火墙入站规则, 打开 OpenList https 端口: ${openlist_https_port}"
			iptables -I INPUT -p tcp --dport ${openlist_https_port} -j ACCEPT -m comment --comment "openlist_rule" >/dev/null 2>&1
		fi
	fi
	# 开启IPV6防火墙端口
	local v6tables=$(which ip6tables)
	local MATCH6=$(ip6tables -t filter -S INPUT | grep "openlist_rule")
	if [ -z "${MATCH6}" ] && [ -n "${v6tables}" ]; then
		if [ "${configDisableHttp}" != "true" -a "${openlist_open_http_port}" == "1" ]; then
			ip6tables -I INPUT -p tcp --dport ${openlist_port} -j ACCEPT -m comment --comment "openlist_rule" >/dev/null 2>&1
		fi
		if [ "${openlist_https}" == "1" -a "${openlist_open_https_port}" == "1" ]; then
			ip6tables -I INPUT -p tcp --dport ${openlist_https_port} -j ACCEPT -m comment --comment "openlist_rule" >/dev/null 2>&1
		fi
	fi

}

close_port() {
	local IPTS=$(iptables -t filter -S | grep -w "openlist_rule" | sed 's/-A/iptables -t filter -D/g')
	if [ -n "${IPTS}" ]; then
		echo_date "🧱关闭本插件在防火墙上打开的所有端口!"
		iptables -t filter -S | grep -w "openlist_rule" | sed 's/-A/iptables -t filter -D/g' >/tmp/openlist_clean.sh
		chmod +x /tmp/openlist_clean.sh
		sh /tmp/openlist_clean.sh >/dev/null 2>&1
		rm /tmp/openlist_clean.sh
	fi
	local v6tables=$(which ip6tables)
	local IPTS6=$(ip6tables -t filter -S | grep -w "openlist_rule" | sed 's/-A/ip6tables -t filter -D/g')
	if [ -n "${IPTS6}" ] && [ -n "${v6tables}" ]; then
		ip6tables -t filter -S | grep -w "openlist_rule" | sed 's/-A/ip6tables -t filter -D/g' >/tmp/openlist_clean.sh
		chmod +x /tmp/openlist_clean.sh
		sh /tmp/openlist_clean.sh >/dev/null 2>&1
		rm /tmp/openlist_clean.sh
	fi
}

start_backup() {
	if [ -d "${OpenListBaseDir}/" ] && [ -d "/tmp/upload/run_openlist/" ]; then
		cd /koolshare/openlist && ls -l data.db* | awk '{print $9}' >/tmp/openlist_db_file_list.tmp
		while read filename; do
			local dbfile_curr="/tmp/upload/run_openlist/${filename}"
			local dbfile_save="${OpenListBaseDir}/${filename}"
			if [ -f "${dbfile_curr}" ]; then
				if [ ! -f "${dbfile_save}" ]; then
					cp -rf ${dbpath_tmp} ${dbfile_save}
					logger "[${0##*/}]: 备份 OpenList ${filename} 数据库!"
				else
					local new=$(md5sum ${dbfile_curr} | awk '{print $1}')
					local old=$(md5sum ${dbfile_save} | awk '{print $1}')
					if [ "${new}" != "${old}" ]; then
						cp -rf ${dbfile_curr} ${dbfile_save}
						logger "[${0##*/}]: OpenList ${filename} 数据库变化, 备份数据库!"
					fi
				fi
			fi
		done </tmp/openlist_db_file_list.tmp
		rm -rf /tmp/openlist_db_file_list.tmp
	fi
}

random_password() {
	# 1. 重新生成密码
	echo_date "🔍重新生成 OpenList 面板的用户和随机密码..."
	make_random_password
	if [ -n "${ADMIN_USER}" -a -n "${ADMIN_PASS}" ]; then
		echo_date "---------------------------------"
		echo_date "😛 OpenList 面板用户: ${ADMIN_USER}"
		echo_date "🔑 OpenList 面板密码: ${ADMIN_PASS}"
		echo_date "---------------------------------"
		dbus set openlist_user=${ADMIN_USER}
		dbus set openlist_pass=${ADMIN_PASS}
	else
		echo_date "⚠️面板账号密码获取失败! 请重启路由后重试!"
	fi
	# 2. 关闭server进程
	echo_date "重启 OpenList 进程..."
	stop_process >/dev/null 2>&1

	# 3. 重启进程
	start >/dev/null 2>&1
	echo_date "✅重启成功!"
}

check_status() {
	local OPENLIST_PID=$(pidof openlist)
	if [ "${openlist_enable}" == "1" ]; then
		if [ -n "${OPENLIST_PID}" ]; then
			if [ "${openlist_watchdog}" == "1" ]; then
				local openlist_time=$(perpls | grep openlist | grep -Eo "uptime.+-s\ " | awk -F" |:|/" '{print $3}')
				if [ -n "${openlist_time}" ]; then
					http_response " OpenList 进程运行正常! (PID: ${OPENLIST_PID}, 守护运行时间: ${openlist_time})"
				else
					http_response " OpenList 进程运行正常! (PID: ${OPENLIST_PID})"
				fi
			else
				http_response " OpenList 进程运行正常! (PID: ${OPENLIST_PID})"
			fi
		else
			http_response " OpenList 进程未运行!"
		fi
	else
		http_response " OpenList 插件未启用"
	fi
}

check_ver() {
	http_response $(curl -s https://raw.githubusercontent.com/Genius-Society/rogsoft_openlist/refs/heads/main/openlist/version)
	dbus set softcenter_module_openlist_version="$(curl -s "https://rogsoft.ddnsto.com/softcenter/app.json.js" | grep -A 10 '"module": "openlist"' | grep '"version":' | sed 's/.*"version": "\([^"]*\)".*/\1/')"
}

update() {
	local local_ver=$(dbus get openlist_version)
	local latest_ver=$(curl -s https://raw.githubusercontent.com/Genius-Society/rogsoft_openlist/refs/heads/main/openlist/version)
	if [ "${local_ver}" == "${latest_ver}" ]; then
		echo_date "OpenList 已是最新版本, 无需更新!"
	else
		echo_date "更新 OpenList 插件中..."
		local status=$(curl -x http://127.0.0.1:23456 -s -o /dev/null -w "%{http_code}" https://github.com)
		if [ "${status}" == "200" ]; then
			wget --no-hsts -c -t 0 -T 30 -e use_proxy=yes -e https_proxy=http://127.0.0.1:23456 -O /tmp/upload/openlist.tar.gz "https://github.com/Genius-Society/rogsoft_openlist/releases/download/${latest_ver}/openlist.tar.gz" 2>&1
		else
			wget --no-hsts -c -t 0 -T 30 -O /tmp/upload/openlist.tar.gz "https://github.com/Genius-Society/rogsoft_openlist/releases/download/${latest_ver}/openlist.tar.gz" 2>&1
		fi
		dbus set soft_name=openlist.tar.gz
		sh /koolshare/scripts/ks_tar_install.sh >/dev/null 2>&1
		echo_date "OpenList 插件已更新!"
	fi
}

case $1 in
start)
	if [ "${openlist_enable}" == "1" ]; then
		sleep 20 # 延迟启动等待虚拟内存挂载
		true >${LOG_FILE}
		start | tee -a ${LOG_FILE}
		echo XU6J03M16 >>${LOG_FILE}
		logger "[软件中心-开机自启]: OpenList自启动成功!"
	else
		logger "[软件中心-开机自启]: OpenList未开启, 不自动启动!"
	fi
	;;
boot_up)
	if [ "${openlist_enable}" == "1" ]; then
		true >${LOG_FILE}
		start | tee -a ${LOG_FILE}
		echo XU6J03M16 >>${LOG_FILE}
	fi
	;;
start_nat)
	if [ "${openlist_enable}" == "1" ]; then
		if [ "${openlist_publicswitch}" == "1" ]; then
			logger "[软件中心-NAT重启]: 打开 OpenList 防火墙端口!"
			sleep 10
			close_port
			sleep 2
			open_port
		else
			logger "[软件中心-NAT重启]: OpenList未开启公网访问, 不打开湍口!"
		fi
	fi
	;;
backup)
	start_backup
	;;
stop)
	stop_plugin
	;;
esac

case $2 in
web_submit)
	set_lock
	true >${LOG_FILE}
	http_response "$1"
	if [ "${openlist_enable}" == "1" ]; then
		echo_date "▶️开启 OpenList!" | tee -a ${LOG_FILE}
		start | tee -a ${LOG_FILE}
	elif [ "${openlist_enable}" == "2" ]; then
		echo_date "🔁重启 OpenList!" | tee -a ${LOG_FILE}
		dbus set openlist_enable=1
		start | tee -a ${LOG_FILE}
	elif [ "${openlist_enable}" == "3" ]; then
		dbus set openlist_enable=1
		random_password | tee -a ${LOG_FILE}
	elif [ "${openlist_enable}" == "4" ]; then
		dbus set openlist_enable=1
		update | tee -a ${LOG_FILE}
	else
		echo_date "ℹ️停止openList!" | tee -a ${LOG_FILE}
		stop_plugin | tee -a ${LOG_FILE}
	fi
	echo XU6J03M16 | tee -a ${LOG_FILE}
	unset_lock
	;;
status)
	check_status
	;;
ver)
	check_ver
	;;
esac
