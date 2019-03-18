#Requires -Modules WebServicesPowerShellProxyBuilder

function Set-ShopifyCredential {
    param (
        [Parameter(Mandatory)]$Credential
    )
    $Script:Credential = $Credential
}
function Get-ShopifyCredential {
    if ($Script:Credential) {
        $Script:Credential
    } else {
        Throw "You need to call Set-ShopifyCredential"
    }
}
function Invoke-ShopifyRestAPIFunction{
    [cmdletbinding()]
    param(
        $HttpMethod,
        $ShopName,
        $Resource,
        $Subresource,
        $Body
        )
    
    $Credential = Get-ShopifyCredential

    $URIRoot = "https://$($Credential.UserName):$($Credential.GetNetworkCredential().Password)@$ShopName.myshopify.com/admin/$($Resource.toLower())"

    if ($Subresource){
        $URI = $URIRoot + "/$Subresource" + ".json"
    } else {
        $URI = $URIRoot + ".json"
    }    
    

    $Response = if ($Body) {
        Invoke-RestMethod -Credential $Credential -Uri $URI -Method $HttpMethod -Body $Body
    } else {
        Invoke-RestMethod -Credential $Credential -Uri $URI -Method $HttpMethod
    }
    
    $Response
}
function Invoke-ShopifyAPIFunction{
    [CmdletBinding()]
    param(
        [parameter(Mandatory)]$ShopName,
        [parameter(Mandatory)]$HttpMethod,
        [parameter(Mandatory)]$Body
    )
    $Credential = Get-ShopifyCredential
    $URI = "https://$ShopName.myshopify.com/admin/api/graphql.json"
    $Headers = @{
        "X-Shopify-Access-Token" = "$($Credential.GetNetworkCredential().Password)"
        "Content-Type" = "application/graphql"
    }

    $Response = Invoke-RestMethod -Method $HttpMethod -Headers $Headers -ContentType "application/graphql" -Uri $URI -Body $Body
    $Response
}
function Invoke-ShopifyGraphQLTest{
    $Body = @"
    {
        shop {
          products(first: 5) {
            edges {
              node {
                id
                handle
              }
            }
            pageInfo {
              hasNextPage
            }
          }
        }
      }
"@

    Invoke-ShopifyAPIFunction -ShopName ospreystoredev -HttpMethod Post -Body $Body
}
function Get-ShopifyRestInventoryItems{
    [cmdletbinding()]
    param(
        [Parameter(mandatory)]$ShopName,
        [Parameter(mandatory)]$ItemIDsSeparatedByCommas
    )
    #$ItemIDsSeparatedByCommas needs to be refactored.

    $Resource = "inventory_items.json?ids=$ItemIDsSeparatedByCommas"

    Invoke-ShopifyRestAPIFunction -HttpMethod Get -Resource $Resource -ShopName $ShopName
}

function Get-ShopifyRestShop{
    [cmdletbinding()]
    param(
        [Parameter(mandatory)]$ShopName
    )
    Invoke-ShopifyRestAPIFunction -HttpMethod Get -Resource Shop -ShopName $ShopName
}

function Get-ShopifyRestProducts{
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName
    )
    Invoke-ShopifyRestAPIFunction -HttpMethod Get -Resource Products -ShopName $ShopName
}

function New-ShopifyRestProduct{
    [cmdletbinding()]
    param(
        [parameter(mandatory)]$ShopName,
        [parameter(mandatory)]$Title,
        [parameter(mandatory)]$Description,
        [parameter(mandatory)]$EBSItemNumber,
        [parameter(mandatory)]$UPC,
        [parameter(mandatory)]$Price,
        $InventoryQuantity = 0
    )
    $Body = @"
{
    "product": {
        "title": "$Title",
        "body_html": "$Description",
        "variants: [
            {
                "price":"$Price",
                "sku":"$EBSItemNumber",
                "barcode":"$UPC"
                "inventory_quantity":"$InventoryQuantity"
            }
        ]
    }
}    
"@
    Invoke-ShopifyRestAPIFunction -HttpMethod Post  -Resource Products @PSBoundParameters
}
