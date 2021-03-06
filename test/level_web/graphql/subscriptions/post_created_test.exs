defmodule LevelWeb.GraphQL.PostCreatedTest do
  use LevelWeb.ChannelCase

  alias Level.Posts

  @operation """
    subscription GroupSubscription(
      $id: ID!
    ) {
      groupSubscription(groupId: $id) {
        __typename
        ... on PostCreatedPayload {
          post {
            id
            subscriptionState
          }
        }
      }
    }
  """

  setup do
    {:ok, result} = create_user_and_space()
    {:ok, Map.put(result, :socket, build_socket(result.user))}
  end

  test "receives an event when a user posts to a group", %{socket: socket, space_user: space_user} do
    {:ok, %{group: group}} = create_group(space_user)

    ref = push_subscription(socket, @operation, %{"id" => group.id})
    assert_reply(ref, :ok, %{subscriptionId: subscription_id}, 1000)

    {:ok, %{post: post}} = Posts.create_post(space_user, group, valid_post_params())

    push_data = %{
      result: %{
        data: %{
          "groupSubscription" => %{
            "__typename" => "PostCreatedPayload",
            "post" => %{
              "id" => post.id,
              "subscriptionState" => "SUBSCRIBED"
            }
          }
        }
      },
      subscriptionId: subscription_id
    }

    assert_push("subscription:data", ^push_data)
  end
end
