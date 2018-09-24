require 'rest-client'
require 'json'
require 'rally_api'
require 'csv'
require 'logger'

class WebhooksSummary
    User_Hash = {}
    User_Permissions_Hash = {}
    @api_key = ""

    def initialize configFile
        headers = RallyAPI::CustomHttpHeader.new({:name => "Blake DeBray", :version => "1.0"})

		file = File.read(configFile)
		config_hash = JSON.parse(file)

		config = {:rally_url => config_hash["rally_url"]}
        
        if (config_hash["api_key"].length > 0)
            @api_key = config_hash["api_key"]
            config[:api_key] = @api_key  
        end

        config[:headers] = headers

		@rally = RallyAPI::RallyRestJson.new(config)
        @csv_file_name = config_hash['output_filename']
    end
    
    def find_user(objectuuid)

        user = User_Hash[objectuuid]
        
        if (user != nil)
            return user
        end
        
		query = RallyAPI::RallyQuery.new()
		query.type = "user"
		query.fetch = "Name,ObjectID,UserName,EmailAddress,DisplayName,FirstName,LastName"
		query.page_size = 1       #optional - default is 200
		query.limit = 1          #optional - default is 99999
		query.order = "Name Asc"
		query.query_string = "(ZuulID = \"#{objectuuid}\")"

		results = @rally.find(query)
        user = results.first

        User_Hash[objectuuid] = user

        return user
	end
    
    def find_user_workspace_permissions(user)
        user_id = user["ObjectID"]
        user_workspaces = User_Permissions_Hash[user_id]
        
        if (user_workspaces != nil)
            return user_workspaces
        end

        query = RallyAPI::RallyQuery.new()
		query.type = "workspacepermission"
		query.fetch = "Name,Workspace,User"
		query.page_size = 200       #optional - default is 200
		query.order = "Name Asc"
        query.query_string = "((User.ObjectID = \"#{user.ObjectID}\") AND (Workspace.State = \"Open\"))"
        results = @rally.find(query)
        User_Permissions_Hash[user_id] = results
        
        return results
    end
    
    def find_user_workspaces(user)
        workspace_names = []
        permissions = find_user_workspace_permissions(user)
        
        #need to iterate to force paging through all permission records (if more than 200)
        #otherwise, we can just map and join the results
        permissions.each { |permission| 
            workspace_name = permission["Workspace"].Name
            workspace_names.push(workspace_name) unless workspace_names.include? workspace_name
            }
        
        return workspace_names.join ';'
        
        #return permissions.map(&:Workspace).uniq.join ';'
    end
    
    def get_webhooks

        url = 'https://rally1.rallydev.com/apps/pigeon/api/v2/webhook?pagesize=200'
        results = []
        totalresults = -1
        
        #iterate through all pages (max page size is 200)
        while results.empty? or results.length < totalresults
            if results.empty?
                paged_url = url
            else
                #append start index if not on the first page (any data in results)
                paged_url = url + "&start=#{results.length + 1}"
            end

            puts "Retrieving webhooks at #{paged_url}..."
            
            response = RestClient.get(
                paged_url,
                headers={'Cookie' => "ZSESSIONID=#{@api_key}"}
            )

            json_response = JSON.parse(response)
            totalresults = json_response['TotalResultCount']
            results += json_response['Results']
            
            puts "Retrieved #{results.length} of #{totalresults}"
        end
    
        return results
    end

	def run
        webhooks = get_webhooks
        
        CSV.open(@csv_file_name, "wb") do |csv|
			csv << ["Webhook","Owner","OwnerLastName","OwnerFirstName","OwnerEmailAddress","Workspaces"]
            
            webhooks.each { | webhook |
                zuulid = webhook['OwnerID'].gsub!('-','')
                
                user = find_user(zuulid)
                user_workspaces = find_user_workspaces(user)

                if (user != nil)
                    userlastname = user["LastName"]
                    userfirstname = user["FirstName"]
                    if (user["DisplayName"] != nil)
                        userdisplay = user["DisplayName"]
                    else
                        userdisplay = user["EmailAddress"]
                    end
                else
                    userdisplay = webhook['OwnerID']
                    userlastname = ""
                    userfirstname = ""
                end

                emaildisplay = user != nil ? user["EmailAddress"] : "(UNKNOWN)" 

                csv << [webhook["Name"],userdisplay,userlastname,userfirstname,emaildisplay,user_workspaces]
            }
        end
    end  
end
    
if (!ARGV[0])
	print "Usage: ruby webhooks_owner_summary.rb config_file_name.json\n"
else
	rtr = WebhooksSummary.new ARGV[0]
	rtr.run
end